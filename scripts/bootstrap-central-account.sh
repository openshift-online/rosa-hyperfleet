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
#   ./bootstrap-central-account.sh [GITHUB_REPO_OWNER] [GITHUB_REPO_NAME] [GITHUB_BRANCH]
#
#   Or use environment variables:
#   GITHUB_REPO_OWNER=myorg GITHUB_REPO_NAME=myrepo ./bootstrap-central-account.sh
# =============================================================================

# Show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [GITHUB_REPO_OWNER] [GITHUB_REPO_NAME] [GITHUB_BRANCH] [ENVIRONMENT]

Bootstrap the central AWS account with pipeline infrastructure.

ARGUMENTS:
    GITHUB_REPO_OWNER    GitHub organization or user (default: 'openshift-online')
    GITHUB_REPO_NAME     Repository name (e.g., 'rosa-regional-platform')
    GITHUB_BRANCH        Branch name (default: 'main')
    ENVIRONMENT          Environment to monitor (e.g., integration, staging, production) (default: 'staging')

OPTIONS:
    -h, --help          Show this help message

ENVIRONMENT VARIABLES:
    GITHUB_REPO_OWNER   GitHub repository owner (default: openshift-online)
    GITHUB_REPO_NAME    GitHub repository name
    GITHUB_BRANCH       Git branch to track (default: main)
    TARGET_ENVIRONMENT  Environment to monitor (default: staging)
    AWS_PROFILE         AWS CLI profile to use

EXAMPLES:
    $0

    # With command-line arguments (custom owner, branch, and environment)
    $0 custom-org rosa-regional-platform feature-branch staging

    # With environment variables
    TARGET_ENVIRONMENT=integration GITHUB_REPO_NAME=rosa-regional-platform $0

    # Override only the owner (uses default branch: main, environment: staging)
    $0 custom-org rosa-regional-platform
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

REGION=$(aws configure get region 2>/dev/null)
REGION=${REGION:-us-east-1}

echo "✅ Authenticated as:"
echo "$AWS_IDENTITY"
echo ""

# Parse command-line arguments or use environment variables (no interactive prompts)
if [ $# -ge 1 ]; then
    # Command-line arguments provided
    GITHUB_REPO_OWNER="$1"
    GITHUB_REPO_NAME="${2:-}"
    GITHUB_BRANCH="${3:-main}"
    TARGET_ENVIRONMENT="${4:-}"
fi

# Set defaults for optional parameters
GITHUB_REPO_OWNER="${GITHUB_REPO_OWNER:-openshift-online}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
TARGET_ENVIRONMENT="${TARGET_ENVIRONMENT:-staging}"

# Validate required inputs
if [ -z "$GITHUB_REPO_NAME" ]; then
    echo "❌ Error: GitHub Repository Name is required"
    echo "   Provide via: command-line argument, environment variable, or interactive prompt"
    exit 1
fi

echo ""
echo "Configuration:"
echo "  Central Account ID: $ACCOUNT_ID"
echo "  AWS Region:         $REGION"
echo "  GitHub Repo:        $GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
echo "  GitHub Branch:      $GITHUB_BRANCH"
echo "  Target Environment: $TARGET_ENVIRONMENT"
echo ""
echo "✅ Proceeding with bootstrap..."

echo ""
echo "==================================================="
echo "Step 1: Creating Terraform State Infrastructure"
echo "==================================================="

# Create state bucket (uses lockfile-based locking)
STATE_BUCKET="terraform-state-${ACCOUNT_ID}"

"${REPO_ROOT}/scripts/bootstrap-state.sh" "$REGION"

echo ""

echo "==================================================="
echo "Step 2: Deploying Pipeline Infrastructure"
echo "==================================================="

cd "${REPO_ROOT}/terraform/config/bootstrap-pipeline"

# Initialize Terraform
echo "Initializing Terraform..."
terraform init -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=bootstrap-pipeline/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="use_lockfile=true"

# Create tfvars file
cat > terraform.tfvars <<EOF
github_repo_owner = "${GITHUB_REPO_OWNER}"
github_repo_name  = "${GITHUB_REPO_NAME}"
github_branch     = "${GITHUB_BRANCH}"
region            = "${REGION}"
environment       = "${TARGET_ENVIRONMENT}"
EOF

echo "Terraform configuration created:"
cat terraform.tfvars
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
echo "🔗 GitHub Connection Authorization:"
echo "   1. Open AWS Console: https://console.aws.amazon.com/codesuite/settings/connections"
echo "   2. Find connections in PENDING state"
echo "   3. Click 'Update pending connection' and authorize with GitHub"
echo ""
echo "To deploy clusters, add shards to config.yaml and run scripts/render.py."
echo "Generated files will appear under deploy/<env>/<region_alias>/."
echo ""

cd "${REPO_ROOT}"
