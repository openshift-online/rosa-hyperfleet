#!/bin/bash
set -euo pipefail

# =============================================================================
# Deploy Manifest to Management Cluster via Maestro (REGIONAL CONTEXT)
# =============================================================================
# This script wraps a Kubernetes manifest in a ManifestWork and deploys it
# to a Management Cluster via the Regional Cluster's Maestro API.
#
# Prerequisites:
# - AWS credentials configured for REGIONAL account
# - awscurl installed (pip install awscurl)
# - Regional cluster infrastructure provisioned (API Gateway available)
# - Management cluster registered as a consumer
# - kubectl installed for YAML to JSON conversion
#
# Usage:
#   ./scripts/deploy-manifest-to-management.sh <manifest-file> <management-tfvars>
#
# Example:
#   ./scripts/deploy-manifest-to-management.sh \
#     my-configmap.yaml \
#     terraform/config/management-cluster/terraform.tfvars
#
# The manifest file can be YAML or JSON and should contain the Kubernetes
# resource(s) to deploy (e.g., ConfigMap, Secret, Deployment, etc.)
#
# =============================================================================

# Color codes for output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Script directory and paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REGIONAL_TF_DIR="${REPO_ROOT}/terraform/config/regional-cluster"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
  echo -e "${RED}✗${NC} $1" >&2
}

# Extract a variable value from a Terraform tfvars file
extract_tfvar() {
  local file="$1"
  local var="$2"

  grep "^${var}[[:space:]]*=" "$file" | \
    sed -E 's/^[^=]+=[[:space:]]*"([^"]+)".*/\1/' | \
    tr -d '\n'
}

# Convert YAML to JSON using kubectl (client-side only, no cluster required)
yaml_to_json() {
  local file="$1"
  if ! kubectl apply -f "$file" --dry-run=client -o json 2>/tmp/kubectl-convert-err; then
    log_error "kubectl failed to convert YAML to JSON"
    cat /tmp/kubectl-convert-err >&2
    exit 1
  fi
}

# Detect if file is YAML or JSON
detect_format() {
  local file="$1"
  local ext="${file##*.}"

  case "$ext" in
    yaml|yml)
      echo "yaml"
      ;;
    json)
      echo "json"
      ;;
    *)
      # Try to detect from content
      if head -1 "$file" | grep -q '^{'; then
        echo "json"
      else
        echo "yaml"
      fi
      ;;
  esac
}

# =============================================================================
# Argument Validation
# =============================================================================

if [ $# -ne 2 ]; then
  log_error "Usage: $0 <manifest-file> <path-to-management-cluster-tfvars>"
  echo ""
  log_info "Example:"
  log_info "  $0 my-configmap.yaml terraform/config/management-cluster/terraform.tfvars"
  echo ""
  log_info "The manifest file should contain the Kubernetes resource to deploy."
  exit 1
fi

MANIFEST_FILE="$1"
MGMT_TFVARS="$2"

if [ ! -f "$MANIFEST_FILE" ]; then
  log_error "Manifest file not found: ${MANIFEST_FILE}"
  exit 1
fi

if [ ! -f "$MGMT_TFVARS" ]; then
  log_error "Management cluster tfvars file not found: ${MGMT_TFVARS}"
  exit 1
fi

# Check for required tools
if ! command -v aws &> /dev/null; then
  log_error "aws CLI is required but not installed"
  log_info "Install from: https://aws.amazon.com/cli/"
  exit 1
fi

if ! command -v awscurl &> /dev/null; then
  log_error "awscurl is required but not installed"
  log_info "Install with: pip install awscurl"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  log_error "jq is required but not installed"
  log_info "Install with: sudo dnf install jq  (or apt-get install jq)"
  exit 1
fi

if ! command -v kubectl &> /dev/null; then
  log_error "kubectl is required but not installed"
  log_info "Install from: https://kubernetes.io/docs/tasks/tools/"
  exit 1
fi

# =============================================================================
# Verify AWS Context (Regional Account)
# =============================================================================

log_info "Verifying AWS credentials (should be REGIONAL account)..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
AWS_REGION=$(aws configure get region || echo "")

if [ -z "$AWS_ACCOUNT_ID" ]; then
  log_error "Unable to verify AWS credentials. Ensure you're authenticated."
  exit 1
fi

if [ -z "$AWS_REGION" ]; then
  log_error "AWS region not configured. Set it with: aws configure set region <region>"
  exit 1
fi

log_success "AWS credentials verified"
log_info "  Account ID: ${AWS_ACCOUNT_ID}"
log_info "  Region:     ${AWS_REGION}"
log_warning "  ⚠️  Ensure this is your REGIONAL account!"
echo ""

# =============================================================================
# Parse Management Cluster Configuration
# =============================================================================

log_info "Parsing management cluster configuration from: ${MGMT_TFVARS}"

CLUSTER_ID=$(extract_tfvar "$MGMT_TFVARS" "cluster_id")

if [ -z "$CLUSTER_ID" ]; then
  log_error "cluster_id not found in ${MGMT_TFVARS}"
  exit 1
fi

log_success "Target cluster: ${CLUSTER_ID}"
echo ""

# =============================================================================
# Get API Gateway URL from Regional Terraform State
# =============================================================================

log_info "Retrieving API Gateway URL from regional terraform state..."

if [ ! -d "$REGIONAL_TF_DIR" ]; then
  log_error "Regional terraform directory not found: ${REGIONAL_TF_DIR}"
  exit 1
fi

API_GATEWAY_URL=$(cd "$REGIONAL_TF_DIR" && terraform output -raw api_gateway_invoke_url 2>/dev/null || echo "")

if [ -z "$API_GATEWAY_URL" ]; then
  log_error "Could not retrieve api_gateway_invoke_url from terraform output"
  log_info ""
  log_info "Ensure the regional cluster is provisioned and terraform state is available:"
  log_info "  cd ${REGIONAL_TF_DIR} && terraform init && terraform output"
  exit 1
fi

log_success "API Gateway URL: ${API_GATEWAY_URL}"
echo ""

# =============================================================================
# Process Manifest File
# =============================================================================

log_info "Processing manifest file: ${MANIFEST_FILE}"

FORMAT=$(detect_format "$MANIFEST_FILE")
log_info "Detected format: ${FORMAT}"

# Convert to JSON if needed
if [ "$FORMAT" = "yaml" ]; then
  MANIFEST_JSON=$(yaml_to_json "$MANIFEST_FILE")
else
  MANIFEST_JSON=$(cat "$MANIFEST_FILE")
fi

# Validate it's valid JSON
if ! echo "$MANIFEST_JSON" | jq empty 2>/dev/null; then
  log_error "Failed to parse manifest as valid JSON"
  exit 1
fi

# Extract resource info for display
RESOURCE_KIND=$(echo "$MANIFEST_JSON" | jq -r '.kind // "Unknown"')
RESOURCE_NAME=$(echo "$MANIFEST_JSON" | jq -r '.metadata.name // "unknown"')
RESOURCE_NS=$(echo "$MANIFEST_JSON" | jq -r '.metadata.namespace // "default"')

log_success "Parsed manifest: ${RESOURCE_KIND}/${RESOURCE_NAME} (namespace: ${RESOURCE_NS})"
echo ""

# =============================================================================
# Create ManifestWork Wrapper
# =============================================================================

TIMESTAMP=$(date +%s)
MANIFESTWORK_NAME="maestro-deploy-${RESOURCE_KIND,,}-${RESOURCE_NAME}-${TIMESTAMP}"

log_info "Creating ManifestWork: ${MANIFESTWORK_NAME}"

# Build the ManifestWork JSON
MANIFESTWORK_JSON=$(jq -n \
  --arg name "$MANIFESTWORK_NAME" \
  --argjson manifest "$MANIFEST_JSON" \
  '{
    "apiVersion": "work.open-cluster-management.io/v1",
    "kind": "ManifestWork",
    "metadata": {
      "name": $name
    },
    "spec": {
      "workload": {
        "manifests": [$manifest]
      },
      "deleteOption": {
        "propagationPolicy": "Foreground"
      }
    }
  }')

log_success "ManifestWork created"
echo ""

# =============================================================================
# Create Payload
# =============================================================================

log_info "Creating payload for cluster: ${CLUSTER_ID}"

PAYLOAD=$(jq -n \
  --arg cluster_id "$CLUSTER_ID" \
  --argjson data "$MANIFESTWORK_JSON" \
  '{
    "cluster_id": $cluster_id,
    "data": $data
  }')

log_success "Payload created"
echo ""

# =============================================================================
# Deploy via Maestro API
# =============================================================================

log_info "Deploying to management cluster via Maestro..."
log_info "  Target:       ${CLUSTER_ID}"
log_info "  Resource:     ${RESOURCE_KIND}/${RESOURCE_NAME}"
log_info "  ManifestWork: ${MANIFESTWORK_NAME}"
echo ""

RESPONSE=$(awscurl -X POST "${API_GATEWAY_URL}/api/v0/work" \
  --service execute-api \
  --region "$AWS_REGION" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>&1)

# Check response
if echo "$RESPONSE" | jq -e '.id' &>/dev/null; then
  log_success "Manifest deployed successfully!"
  echo ""
  echo "Response:"
  echo "$RESPONSE" | jq .
else
  # Check if it's an error response
  if echo "$RESPONSE" | jq -e '.error' &>/dev/null; then
    log_error "Deployment failed"
    echo ""
    echo "Error response:"
    echo "$RESPONSE" | jq .
    exit 1
  else
    # Might be a success without expected fields
    log_warning "Deployment submitted (response format unexpected)"
    echo ""
    echo "Response:"
    echo "$RESPONSE"
  fi
fi

echo ""

# =============================================================================
# Display Summary
# =============================================================================

echo "=============================================================================="
echo -e "${GREEN}Deployment Complete!${NC}"
echo "=============================================================================="
echo ""
echo "Manifest Details:"
echo "  Kind:        ${RESOURCE_KIND}"
echo "  Name:        ${RESOURCE_NAME}"
echo "  Namespace:   ${RESOURCE_NS}"
echo ""
echo "ManifestWork:"
echo "  Name:        ${MANIFESTWORK_NAME}"
echo "  Target:      ${CLUSTER_ID}"
echo ""
echo "=============================================================================="
echo "VERIFICATION"
echo "=============================================================================="
echo ""
echo "Check resource bundle status:"
echo "  awscurl --service execute-api --region ${AWS_REGION} \\"
echo "    '${API_GATEWAY_URL}/api/v0/resource_bundles' | jq '.items[]'"
echo ""
echo "On the management cluster, verify the resource was created:"
echo "  kubectl get ${RESOURCE_KIND,,} ${RESOURCE_NAME} -n ${RESOURCE_NS}"
echo ""
echo "=============================================================================="
echo ""
