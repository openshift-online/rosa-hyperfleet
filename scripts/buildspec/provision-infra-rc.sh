#!/usr/bin/env bash
# Provision or destroy Regional Cluster infrastructure.
# Called from: terraform/config/pipeline-regional-cluster/buildspec-provision-infra.yml
set -euo pipefail

echo "=========================================="
echo "Provisioning Regional Cluster Infrastructure"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Load terraform variables from deploy/ JSON
source scripts/pipeline-common/load-deploy-config.sh regional

# Save central credentials as a named AWS profile so Terraform's aws.central
# provider can access the central account after use_mc_account switches
# ambient creds to the target account.
aws configure set aws_access_key_id     "$_CENTRAL_AWS_ACCESS_KEY_ID"     --profile central
aws configure set aws_secret_access_key "$_CENTRAL_AWS_SECRET_ACCESS_KEY" --profile central
aws configure set aws_session_token     "$_CENTRAL_AWS_SESSION_TOKEN"     --profile central
aws configure set region                "${TARGET_REGION}"                --profile central
export TF_VAR_central_aws_profile="central"

# Assume target account role for both state and resource operations
use_mc_account
echo ""

echo "Deploying to account: ${TARGET_ACCOUNT_ID}"
echo "  Region: ${TARGET_REGION}"
echo "  Regional ID: ${REGIONAL_ID}"
echo ""

# Configure Terraform backend (state in target account)
export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="regional-cluster/${REGIONAL_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

echo "Terraform backend:"
echo "  Bucket: $TF_STATE_BUCKET (target account: $TARGET_ACCOUNT_ID)"
echo "  Key: $TF_STATE_KEY"
echo "  Region: $TF_STATE_REGION"
echo ""

# Set Terraform variables from deploy config and CodeBuild env vars
export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_owner="${OWNER}"
export TF_VAR_organization="${ORGANIZATION}"
export TF_VAR_app="${APP}"

# Set repository URL and branch with proper fallback handling for set -u
# Note: CODEBUILD_SOURCE_VERSION contains S3 artifact location, not git branch
_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

# Build allowed accounts list: target account + all MC accounts
_ALLOWED_ACCOUNTS="${TARGET_ACCOUNT_ID}"
# Read MC account IDs from rendered config (may contain SSM references)
_MC_ACCOUNTS=$(jq -r '.management_cluster_account_ids // [] | .[]' "$DEPLOY_CONFIG_FILE" 2>/dev/null || true)
for _ACCT in $_MC_ACCOUNTS; do
    if [[ "$_ACCT" =~ ^ssm:// ]]; then
        _SSM_PARAM="${_ACCT#ssm://}"
        _ACCT=$(aws ssm get-parameter --name "$_SSM_PARAM" --with-decryption --query 'Parameter.Value' --output text --region "${TARGET_REGION}" 2>/dev/null || true)
    fi
    if [[ -n "$_ACCT" ]]; then
        _ALLOWED_ACCOUNTS="${_ALLOWED_ACCOUNTS},${_ACCT}"
    fi
done
export TF_VAR_api_additional_allowed_accounts="${_ALLOWED_ACCOUNTS}"

# Set container image for ECS tasks (bastion and bootstrap)
if [ -z "${PLATFORM_IMAGE:-}" ]; then
    echo "ERROR: PLATFORM_IMAGE is not set or empty; cannot set TF_VAR_container_image" >&2
    exit 1
fi
export TF_VAR_container_image="${PLATFORM_IMAGE}"

export TF_VAR_enable_bastion="${ENABLE_BASTION}"

export TF_VAR_enable_cloudtrail=$(parseBool '.enable_cloudtrail' false "$DEPLOY_CONFIG_FILE")

# Load node_instance_types from deploy config (should be set in config.yaml)
export TF_VAR_node_instance_types=$(jq -c '.node_instance_types' "$DEPLOY_CONFIG_FILE")

# Set DNS variables (optional — when ENVIRONMENT_DOMAIN is set, creates regional
# DNS zone and custom API domain)
if [ -n "${ENVIRONMENT_DOMAIN:-}" ]; then
    export TF_VAR_environment_domain="${ENVIRONMENT_DOMAIN}"
fi
if [ -n "${ENVIRONMENT_HOSTED_ZONE_ID:-}" ]; then
    export TF_VAR_environment_hosted_zone_id="${ENVIRONMENT_HOSTED_ZONE_ID}"
fi

# Extract regional_id and environment from rendered config
export TF_VAR_regional_id=$(jq -r '.regional_id' "$DEPLOY_CONFIG_FILE")
export TF_VAR_environment=$(jq -r '.environment' "$DEPLOY_CONFIG_FILE")

echo "Terraform variables:"
echo "  Region: $TF_VAR_region"
echo "  App Code: $TF_VAR_app_code"
echo "  Service Phase: $TF_VAR_service_phase"
echo "  Cost Center: $TF_VAR_cost_center"
echo "  Owner: $TF_VAR_owner"
echo "  Organization: $TF_VAR_organization"
echo "  App: $TF_VAR_app"
echo "  Repository URL: $TF_VAR_repository_url"
echo "  Repository Branch: $TF_VAR_repository_branch"
echo "  API Additional Allowed Accounts: $TF_VAR_api_additional_allowed_accounts"
echo "  Enable Bastion: $TF_VAR_enable_bastion"
echo "  Enable CloudTrail: $TF_VAR_enable_cloudtrail"
echo "  Node Instance Types: $TF_VAR_node_instance_types"
echo "  Environment Domain: ${TF_VAR_environment_domain:-<not set>}"
echo "  Environment Hosted Zone ID: ${TF_VAR_environment_hosted_zone_id:-<not set>}"
echo "  Regional ID: $TF_VAR_regional_id"
echo "  Environment: $TF_VAR_environment"
echo ""

export ENVIRONMENT="${ENVIRONMENT:-staging}"

# Read delete flag from config (GitOps-driven deletion)
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
# Manual override: IS_DESTROY pipeline variable takes precedence
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

echo ""
if [ "${DELETE_FLAG}" == "true" ]; then
    echo ">>> MODE: TEARDOWN <<<"
else
    echo ">>> MODE: PROVISION <<<"
fi
echo ""

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

cd terraform/config/regional-cluster
terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}" \
    -backend-config="use_lockfile=true"
terraform "${TERRAFORM_ACTION}" -auto-approve
