#!/usr/bin/env bash
# Build and push the platform container image to ECR
#
# The image is tagged with the SHA256 of the Dockerfile (first 12 chars).
# If an image with that tag already exists in ECR, the build is skipped.
#
# Uses the current AWS credentials to find the platform ECR repository.
#
# Usage:
#   ./scripts/build-platform-image.sh
#
# Set CONTAINER_RUNTIME=docker or CONTAINER_RUNTIME=podman to override auto-detection.

set -euo pipefail

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

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: Dockerfile not found: $DOCKERFILE"
  exit 1
fi

# Compute the image tag from the Dockerfile content (matches Terraform's sha256(), first 12 hex chars)
if command -v sha256sum &>/dev/null; then
  IMAGE_TAG=$(sha256sum "$DOCKERFILE" | cut -c1-12)
elif command -v shasum &>/dev/null; then
  IMAGE_TAG=$(shasum -a 256 "$DOCKERFILE" | cut -c1-12)
else
  echo "Error: Neither sha256sum nor shasum found."
  exit 1
fi

# Find the platform ECR repository in the current account/region
echo "Looking up platform ECR repository..."
ECR_URL=$(aws ecr describe-repositories \
  --query "repositories[?ends_with(repositoryName, '/platform')].repositoryUri | [0]" \
  --output text 2>/dev/null)

if [ -z "$ECR_URL" ] || [ "$ECR_URL" = "None" ]; then
  echo "Error: No platform ECR repository found in this account/region."
  echo "Make sure 'terraform apply' has been run first."
  exit 1
fi

# Extract registry and repo name
ECR_REGISTRY="${ECR_URL%%/*}"
ECR_REPO="${ECR_URL#*/}"
REGION=$(echo "$ECR_REGISTRY" | sed 's/.*\.ecr\.\(.*\)\.amazonaws\.com/\1/')

echo "ECR Repository: $ECR_URL"
echo "Image tag:      $IMAGE_TAG"
echo "Region:         $REGION"
echo ""

# Check if the image already exists in ECR
echo "Checking if image already exists in ECR..."
if aws ecr describe-images \
    --repository-name "$ECR_REPO" \
    --image-ids imageTag="$IMAGE_TAG" \
    --region "$REGION" &>/dev/null; then
  echo "Image ${ECR_URL}:${IMAGE_TAG} already exists in ECR. Skipping build."
  exit 0
fi

echo "Image not found in ECR. Building..."
echo ""

# Authenticate with ECR
echo "Authenticating with ECR..."
aws ecr get-login-password --region "$REGION" | $CONTAINER_RUNTIME login --username AWS --password-stdin "$ECR_REGISTRY"
echo ""

# Build the image
echo "Building platform image from ${DOCKERFILE}..."
$CONTAINER_RUNTIME build --platform linux/amd64 -t "${ECR_URL}:${IMAGE_TAG}" "$DOCKERFILE_DIR"
echo ""

# Push the image
echo "Pushing image to ECR..."
$CONTAINER_RUNTIME push "${ECR_URL}:${IMAGE_TAG}"
echo ""

echo "Done. Image pushed to: ${ECR_URL}:${IMAGE_TAG}"
