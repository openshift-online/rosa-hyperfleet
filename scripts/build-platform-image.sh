#!/usr/bin/env bash
# Build and push the platform container image to public ECR
#
# The image is tagged with the SHA256 of the Dockerfile (first 12 chars).
# If an image with that tag already exists in ECR, the build is skipped.
#
# Public ECR repositories must be managed from us-east-1.
#
# Usage:
#   ./scripts/build-platform-image.sh
#
# Set CONTAINER_RUNTIME=docker or CONTAINER_RUNTIME=podman to override auto-detection.

set -euo pipefail

echo "=========================================="
echo "Building Platform Image"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Detect container runtime: honor CONTAINER_RUNTIME env var, otherwise auto-detect
if [ -n "${CONTAINER_RUNTIME:-}" ]; then
  if ! command -v "$CONTAINER_RUNTIME" &>/dev/null; then
    echo "Error: CONTAINER_RUNTIME='$CONTAINER_RUNTIME' not found in PATH."
    exit 1
  fi
else
  if command -v docker &>/dev/null; then
    CONTAINER_RUNTIME="docker"
  elif command -v podman &>/dev/null; then
    CONTAINER_RUNTIME="podman"
  else
    echo "Error: Neither docker nor podman found. Install one or set CONTAINER_RUNTIME."
    exit 1
  fi
fi

echo "Using container runtime: $CONTAINER_RUNTIME"

DOCKERFILE_DIR="terraform/modules/platform-image"
DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile"
PROVIDER_VERSIONS_FILE="terraform/provider-versions.yaml"

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: Dockerfile not found: $DOCKERFILE"
  exit 1
fi

if [ ! -f "$PROVIDER_VERSIONS_FILE" ]; then
  echo "Error: Provider versions file not found: $PROVIDER_VERSIONS_FILE"
  exit 1
fi

# Extract the canonical Terraform version from provider-versions.yaml
TERRAFORM_VERSION=$(grep '^terraform_version:' "$PROVIDER_VERSIONS_FILE" | sed 's/terraform_version:[[:space:]]*"\(.*\)"/\1/')
if [ -z "$TERRAFORM_VERSION" ]; then
  echo "Error: Could not extract terraform_version from $PROVIDER_VERSIONS_FILE"
  exit 1
fi
echo "Terraform version: $TERRAFORM_VERSION"

# Compute the image tag to match Terraform's combined_hash local:
# sha256(sha256(Dockerfile) + sha256(provider-versions.yaml) + sha256(generate-provider-init.py)), first 12 chars
if command -v sha256sum &>/dev/null; then
  _sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum &>/dev/null; then
  _sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "Error: Neither sha256sum nor shasum found."
  exit 1
fi
DOCKERFILE_HASH=$(_sha256 "$DOCKERFILE")
PROVIDER_VERSIONS_HASH=$(_sha256 "$PROVIDER_VERSIONS_FILE")
GENERATOR_HASH=$(_sha256 "${DOCKERFILE_DIR}/generate-provider-init.py")
IMAGE_TAG=$(printf '%s%s%s' "$DOCKERFILE_HASH" "$PROVIDER_VERSIONS_HASH" "$GENERATOR_HASH" | sha256sum | cut -c1-12)

# Find the platform public ECR repository in the current account
echo "Looking up platform public ECR repository..."

if [ -n "${PLATFORM_ECR_REPO:-}" ]; then
  # Explicit override via environment variable
  ECR_URL="${PLATFORM_ECR_REPO}"
  echo "Using PLATFORM_ECR_REPO from environment: $ECR_URL"
else
  # Query for repositories ending with '/platform' and validate uniqueness
  ECR_MATCHES=$(aws ecr-public describe-repositories \
    --region us-east-1 \
    --query "repositories[?ends_with(repositoryName, '/platform')].[repositoryUri, repositoryName]" \
    --output json 2>/dev/null || echo "[]")

  MATCH_COUNT=$(echo "$ECR_MATCHES" | jq 'length')

  if [ "$MATCH_COUNT" -eq 0 ]; then
    echo "Error: No platform public ECR repository found in this account."
    echo "Make sure 'terraform apply' has been run first."
    exit 1
  elif [ "$MATCH_COUNT" -gt 1 ]; then
    echo "Error: Multiple repositories matching '/platform' found:"
    echo "$ECR_MATCHES" | jq -r '.[] | "  - \(.[1]): \(.[0])"'
    echo ""
    echo "Set PLATFORM_ECR_REPO to the desired repository URI to disambiguate."
    exit 1
  fi

  ECR_URL=$(echo "$ECR_MATCHES" | jq -r '.[0][0]')

  if [ -z "$ECR_URL" ] || [ "$ECR_URL" = "null" ]; then
    echo "Error: Failed to determine ECR repository URI."
    exit 1
  fi
fi

echo "ECR Repository: $ECR_URL"
echo "Image tag:      $IMAGE_TAG"
echo ""

# Check if the image already exists in ECR
echo "Checking if image already exists in ECR..."
# Public ECR URI format: public.ecr.aws/<alias>/<repo-name>
# Extract the repository name by removing the "public.ecr.aws/<alias>/" prefix
ECR_REPO=$(echo "$ECR_URL" | sed 's|^public\.ecr\.aws/[^/]*/||')
if aws ecr-public describe-images \
    --region us-east-1 \
    --repository-name "$ECR_REPO" \
    --image-ids imageTag="$IMAGE_TAG" &>/dev/null; then
  echo "Image ${ECR_URL}:${IMAGE_TAG} already exists in ECR. Skipping build."
  exit 0
fi

echo "Image not found in ECR. Building..."
echo ""

# Authenticate with public ECR (required for pushing)
echo "Authenticating with public ECR..."
aws ecr-public get-login-password --region us-east-1 | $CONTAINER_RUNTIME login --username AWS --password-stdin public.ecr.aws
echo ""

# Build the image (using repo root as context to access provider-versions.yaml)
echo "Building platform image from ${DOCKERFILE}..."
$CONTAINER_RUNTIME build --platform linux/amd64 \
  --build-arg TERRAFORM_VERSION="${TERRAFORM_VERSION}" \
  -t "${ECR_URL}:${IMAGE_TAG}" \
  -f "$DOCKERFILE" .
echo ""

# Push the image
echo "Pushing image to ECR..."
$CONTAINER_RUNTIME push "${ECR_URL}:${IMAGE_TAG}"
echo ""

echo "Done. Image pushed to: ${ECR_URL}:${IMAGE_TAG}"
