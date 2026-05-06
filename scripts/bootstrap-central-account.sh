#!/bin/bash
set -euo pipefail

# =============================================================================
# Bootstrap Central AWS Account
# =============================================================================
# This script bootstraps the central AWS account with:
# 1. Terraform state infrastructure (S3 bucket with lockfile-based locking)
# 2. Regional cluster pipeline infrastructure
# 3. Management cluster pipeline infrastructure
#
# Prerequisites:
# - AWS CLI configured with central account credentials
# - Terraform >= 1.14.3 installed
# - GitHub repository set up
#
# Usage:
#   GITHUB_REPOSITORY=owner/repo GITHUB_BRANCH=main ./bootstrap-central-account.sh
#
#   Or with command-line arguments:
#   ./bootstrap-central-account.sh owner/repo main staging
# =============================================================================

# Show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [GITHUB_REPOSITORY] [GITHUB_BRANCH] [ENVIRONMENT]

Bootstrap the central AWS account with pipeline infrastructure.

ARGUMENTS:
    GITHUB_REPOSITORY    GitHub repository in owner/name format (default: 'openshift-online/rosa-regional-platform')
    GITHUB_BRANCH        Branch name (default: 'main')
    ENVIRONMENT          Environment to monitor (e.g., integration, staging, production) (default: 'staging')

OPTIONS:
    -h, --help          Show this help message

ENVIRONMENT VARIABLES:
    GITHUB_REPOSITORY   GitHub repository in owner/name format (e.g., 'openshift-online/rosa-regional-platform')
    GITHUB_BRANCH       Git branch to track (default: main)
    TARGET_ENVIRONMENT  Environment to monitor (default: staging)
    SLACK_WEBHOOK_SSM_PARAM  SSM Parameter Store path containing Slack webhook URL (optional, only for stage/staging/production/integration)
                             Default: /rosa-regional/slack/webhook-url
    AWS_PROFILE         AWS CLI profile to use

EXAMPLES:
    # With environment variables (recommended)
    GITHUB_REPOSITORY=openshift-online/rosa-regional-platform GITHUB_BRANCH=bugfix-environment TARGET_ENVIRONMENT=brian $0

    # With command-line arguments
    $0 custom-org/rosa-regional-platform feature-branch staging

    # Using defaults (openshift-online/rosa-regional-platform, main, staging)
    $0
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            # First positional argument found, stop parsing flags
            break
            ;;
    esac
done

# Determine repo root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🚀 ROSA Regional Platform - Central Account Bootstrap"
echo "======================================================"
echo ""
echo "Repository Root: $REPO_ROOT"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo "❌ Error: AWS CLI not found. Please install AWS CLI."
    exit 1
fi

if ! command -v terraform &> /dev/null; then
    echo "❌ Error: Terraform not found. Please install Terraform >= 1.14.3"
    exit 1
fi

# Get current AWS identity (capture once to avoid duplicate calls)
echo "Checking AWS credentials..."
if ! AWS_IDENTITY=$(aws sts get-caller-identity --no-cli-pager 2>&1); then
    echo "❌ Error: Failed to authenticate with AWS"
    echo "$AWS_IDENTITY"
    exit 1
fi

ACCOUNT_ID=$(echo "$AWS_IDENTITY" | jq -r '.Account')

if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "❌ Error: Invalid AWS account ID: '$ACCOUNT_ID'"
    exit 1
fi

REGION=$(aws configure get region 2>/dev/null || echo "")
REGION=${REGION:-us-east-1}

echo "✅ Authenticated as:"
echo "$AWS_IDENTITY"
echo ""

# Parse command-line arguments or use environment variables (no interactive prompts)
if [ $# -ge 1 ]; then
    # Command-line arguments provided
    GITHUB_REPOSITORY="$1"
    GITHUB_BRANCH="${2:-main}"
    TARGET_ENVIRONMENT="${3:-}"
fi

# Set defaults for optional parameters
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-openshift-online/rosa-regional-platform}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
TARGET_ENVIRONMENT="${TARGET_ENVIRONMENT:-staging}"
NAME_PREFIX="${NAME_PREFIX:-}"
SLACK_WEBHOOK_SSM_PARAM="${SLACK_WEBHOOK_SSM_PARAM:-/rosa-regional/slack/webhook-url}"

# Validate repository format (must be owner/name)
if [[ ! "$GITHUB_REPOSITORY" =~ ^[^/]+/[^/]+$ ]]; then
    echo "❌ Error: GITHUB_REPOSITORY must be in 'owner/name' format"
    echo "   Example: openshift-online/rosa-regional-platform"
    exit 1
fi

# Helper function to check if element is in array
contains_element() {
    local element="$1"
    shift
    local arr=("$@")
    for e in "${arr[@]}"; do
        [[ "$e" == "$element" ]] && return 0
    done
    return 1
}

# Verify SSM parameter for monitored environments
# Must match Terraform: terraform/config/central-account-bootstrap/main.tf
MONITORED_ENVS=("stage" "staging" "production" "integration")
SLACK_NOTIFICATIONS_ENABLED=false
if contains_element "$TARGET_ENVIRONMENT" "${MONITORED_ENVS[@]}"; then
    # This environment requires Slack notifications
    # Verify the SSM parameter exists (Lambda will fetch the actual value at runtime)
    echo "Verifying Slack webhook SSM parameter: $SLACK_WEBHOOK_SSM_PARAM"

    if aws ssm get-parameter \
        --name "$SLACK_WEBHOOK_SSM_PARAM" \
        --query 'Parameter.Name' \
        --output text \
        --region "$REGION" >/dev/null 2>&1; then
        echo "✅ SSM parameter verified: $SLACK_WEBHOOK_SSM_PARAM"
        SLACK_NOTIFICATIONS_ENABLED=true
    else
        # For monitored environments, fail fast if SSM parameter doesn't exist
        echo "❌ Error: SSM parameter not found: $SLACK_WEBHOOK_SSM_PARAM"
        echo "   Environment '$TARGET_ENVIRONMENT' requires Slack notifications."
        echo "   Please ensure the SSM parameter exists and contains a valid webhook URL."
        echo ""
        echo "   To create the parameter, run:"
        echo "   aws ssm put-parameter --name '$SLACK_WEBHOOK_SSM_PARAM' \\"
        echo "     --value 'https://hooks.slack.com/services/...' \\"
        echo "     --type SecureString --region $REGION"
        exit 1
    fi
else
    # Non-monitored environment - notifications not required
    echo "ℹ️  Environment '${TARGET_ENVIRONMENT}' does not require Slack notifications (skipping)"
fi

echo ""
echo "Configuration:"
echo "  Central Account ID: $ACCOUNT_ID"
echo "  AWS Region:         $REGION"
echo "  GitHub Repo:        $GITHUB_REPOSITORY"
echo "  GitHub Branch:      $GITHUB_BRANCH"
echo "  Target Environment: $TARGET_ENVIRONMENT"
echo "  Name Prefix:        ${NAME_PREFIX:-<none>}"
if [[ "$SLACK_NOTIFICATIONS_ENABLED" == "true" ]]; then
    echo "  Slack Notifications: enabled (SSM: $SLACK_WEBHOOK_SSM_PARAM)"
else
    echo "  Slack Notifications: disabled"
fi
echo ""
echo "✅ Proceeding with bootstrap..."

echo ""
echo "==================================================="
echo "Step 1: Creating Terraform State Infrastructure"
echo "==================================================="

# Create state bucket (uses lockfile-based locking)
STATE_BUCKET="terraform-state-${ACCOUNT_ID}"

"${REPO_ROOT}/scripts/bootstrap-state.sh" --central "$REGION"

echo ""

echo "==================================================="
echo "Step 2: Ensuring GitHub CodeStar Connection"
echo "==================================================="

CODESTAR_CONNECTION_NAME="rosa-regional-github-shared"

# Check if connection already exists
EXISTING_ARN=$(aws codestar-connections list-connections \
    --provider-type-filter GitHub \
    --query "Connections[?ConnectionName=='${CODESTAR_CONNECTION_NAME}'].ConnectionArn | [0]" \
    --output text --no-cli-pager 2>/dev/null)

if [[ -n "$EXISTING_ARN" && "$EXISTING_ARN" != "None" ]]; then
    echo "✅ Found existing CodeStar connection: $EXISTING_ARN"
    GITHUB_CONNECTION_ARN="$EXISTING_ARN"
else
    echo "Creating new CodeStar connection: ${CODESTAR_CONNECTION_NAME}"
    GITHUB_CONNECTION_ARN=$(aws codestar-connections create-connection \
        --provider-type GitHub \
        --connection-name "${CODESTAR_CONNECTION_NAME}" \
        --query "ConnectionArn" \
        --output text --no-cli-pager)
    echo "✅ Created CodeStar connection: $GITHUB_CONNECTION_ARN"
    echo ""
    echo "⚠️  The connection is in PENDING state. You must authorize it before continuing:"
    echo "   1. Open AWS Console: https://console.aws.amazon.com/codesuite/settings/connections"
    echo "   2. Find '${CODESTAR_CONNECTION_NAME}' in PENDING state"
    echo "   3. Click 'Update pending connection' and authorize with GitHub"
fi

# Verify connection is AVAILABLE before proceeding
CONNECTION_STATUS=$(aws codestar-connections get-connection \
    --connection-arn "$GITHUB_CONNECTION_ARN" \
    --query "Connection.ConnectionStatus" \
    --output text --no-cli-pager)

if [[ "$CONNECTION_STATUS" != "AVAILABLE" ]]; then
    echo ""
    echo "⚠️  Connection status is: $CONNECTION_STATUS"
    echo "   The pipeline provisioner requires an AVAILABLE connection to function."
    echo "   Please authorize the connection in the AWS Console before continuing."
    echo ""

    POLL_INTERVAL=15
    MAX_WAIT=300
    WAITED=0
    echo "   Polling every ${POLL_INTERVAL}s (timeout: ${MAX_WAIT}s)..."
    while [[ "$CONNECTION_STATUS" != "AVAILABLE" && "$WAITED" -lt "$MAX_WAIT" ]]; do
        sleep "$POLL_INTERVAL"
        WAITED=$((WAITED + POLL_INTERVAL))
        CONNECTION_STATUS=$(aws codestar-connections get-connection \
            --connection-arn "$GITHUB_CONNECTION_ARN" \
            --query "Connection.ConnectionStatus" \
            --output text --no-cli-pager)
        echo "   [$WAITED/${MAX_WAIT}s] Connection status: $CONNECTION_STATUS"
    done

    if [[ "$CONNECTION_STATUS" != "AVAILABLE" ]]; then
        echo "❌ Timed out waiting for connection to become AVAILABLE (status: $CONNECTION_STATUS)."
        exit 1
    fi
fi

echo "✅ CodeStar connection is AVAILABLE"

echo ""
echo "==================================================="
echo "Step 3: Deploying Pipeline Infrastructure"
echo "==================================================="

cd "${REPO_ROOT}/terraform/config/central-account-bootstrap"

# Initialize Terraform
echo "Initializing Terraform..."
terraform init -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=${NAME_PREFIX:+${NAME_PREFIX}-}central-account-bootstrap/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="use_lockfile=true"

# Import the existing CodeStar connection into terraform state so it can
# reference the ARN directly (instead of passing it as a variable).
# The connection is shared across runs and is removed from state before
# destroy so it persists.
echo "Importing CodeStar connection into Terraform state..."
terraform import -var="github_repository=${GITHUB_REPOSITORY}" \
    aws_codestarconnections_connection.github "$GITHUB_CONNECTION_ARN" 2>/dev/null || true

# Load tag values from rendered pipeline-provisioner-inputs if available
_PROVISIONER_JSON="${REPO_ROOT}/deploy/${TARGET_ENVIRONMENT}/${REGION}/pipeline-provisioner-inputs/terraform.json"
if [ -f "$_PROVISIONER_JSON" ]; then
    APP_CODE=$(jq -r '.app_code // "infra"' "$_PROVISIONER_JSON")
    SERVICE_PHASE=$(jq -r '.service_phase // "dev"' "$_PROVISIONER_JSON")
    COST_CENTER=$(jq -r '.cost_center // "000"' "$_PROVISIONER_JSON")
    OWNER=$(jq -r '.owner // "placeholder"' "$_PROVISIONER_JSON")
    ORGANIZATION=$(jq -r '.organization // "placeholder"' "$_PROVISIONER_JSON")
    APP=$(jq -r '.app // "rosa-regionality"' "$_PROVISIONER_JSON")
    echo "Loaded tags from: $_PROVISIONER_JSON"
else
    APP_CODE="infra"
    SERVICE_PHASE="dev"
    COST_CENTER="000"
    OWNER="placeholder"
    ORGANIZATION="placeholder"
    APP="rosa-regionality"
    echo "ℹ️  No rendered config found at $_PROVISIONER_JSON, using default tags"
fi

# Create tfvars file
cat > terraform.tfvars <<EOF
github_repository     = "${GITHUB_REPOSITORY}"
github_branch         = "${GITHUB_BRANCH}"
region                = "${REGION}"
environment           = "${TARGET_ENVIRONMENT}"
name_prefix           = "${NAME_PREFIX}"
slack_webhook_ssm_param = "${SLACK_WEBHOOK_SSM_PARAM}"
app_code              = "${APP_CODE}"
service_phase         = "${SERVICE_PHASE}"
cost_center           = "${COST_CENTER}"
owner                  = "${OWNER}"
organization           = "${ORGANIZATION}"
app                    = "${APP}"
EOF

echo "Terraform configuration created (terraform.tfvars)"
echo ""

# Run terraform plan
echo "Running Terraform plan..."
terraform plan -var-file=terraform.tfvars -out=tfplan

echo ""
echo "✅ Applying Terraform configuration..."
terraform apply tfplan

echo ""
echo "==================================================="
echo "✅ Bootstrap Complete!"
echo "==================================================="
echo ""
echo "To deploy clusters, add region deployments to config.yaml and run scripts/render.py."
echo "Generated files will appear under deploy/<env>/<name>/."
echo ""

cd "${REPO_ROOT}"
