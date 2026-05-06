#!/usr/bin/env bash
# Provision or destroy Management Cluster infrastructure.
# Called from: terraform/config/pipeline-management-cluster/buildspec-provision-infra.yml
set -euo pipefail

echo "=========================================="
echo "Provisioning Management Cluster Infrastructure"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Load terraform variables from deploy/ JSON
source scripts/pipeline-common/load-deploy-config.sh management

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

echo "Deploying to account: ${TARGET_ACCOUNT_ID}"
echo "  Region: ${TARGET_REGION}"
echo "  Management ID: ${MANAGEMENT_ID}"
echo ""

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

# =====================================================================
# Phase 1: Read IoT cert/config outputs from RC account state
# (skipped on destroy — IoT resources already cleaned up by Mint-IoT stage)
# =====================================================================
if [ "${DELETE_FLAG}" == "true" ]; then
    # Terraform still evaluates file() during destroy; provide empty placeholders.
    # (Can't use /dev/null — the cleanup line below would rm it in the container.)
    export TF_VAR_maestro_agent_cert_file=$(mktemp)
    export TF_VAR_maestro_agent_config_file=$(mktemp)
else
    echo "Reading IoT certificate data from RC account state..."
    use_rc_account
    source scripts/read-iot-state.sh "$RESOLVED_REGIONAL_ACCOUNT_ID" "$CLUSTER_ID" "$TARGET_REGION"

    # Read RHOBS API URL from RC terraform state (custom domain or invoke URL)
    echo "Reading API URL from RC terraform state..."
    _RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
    _RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "regional")
    _RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
    _RC_TF_DIR="terraform/config/regional-cluster"
    (cd "$_RC_TF_DIR" && terraform init -reconfigure \
        -backend-config="bucket=${_RC_STATE_BUCKET}" \
        -backend-config="key=${_RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null 2>&1)
    export TF_VAR_rhobs_api_url=$(cd "$_RC_TF_DIR" && terraform output -raw rhobs_api_url 2>/dev/null || echo "")
    echo "  RHOBS API URL:  ${TF_VAR_rhobs_api_url:-<not available>}"
fi

# =====================================================================
# Phase 2: Apply/Destroy MC infrastructure
# =====================================================================
use_mc_account

# Configure Terraform backend (state in MC target account)
export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="management-cluster/${MANAGEMENT_ID}.tfstate"
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
export TF_VAR_management_id="${CLUSTER_ID:-mgmt-cluster-01}"
export TF_VAR_environment="${ENVIRONMENT:-staging}"
export TF_VAR_regional_aws_account_id="${RESOLVED_REGIONAL_ACCOUNT_ID}"

# TF_VAR_maestro_agent_cert_file and TF_VAR_maestro_agent_config_file
# are already exported by read-iot-state.sh

# Set repository URL and branch
_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

# Set container image for ECS tasks (bastion and bootstrap)
if [ -z "${PLATFORM_IMAGE:-}" ]; then
    echo "ERROR: PLATFORM_IMAGE is not set or empty; cannot set TF_VAR_container_image" >&2
    exit 1
fi
export TF_VAR_container_image="${PLATFORM_IMAGE}"

export TF_VAR_enable_bastion="${ENABLE_BASTION}"

# Load node_instance_types from deploy config (should be set in config.yaml)
export TF_VAR_node_instance_types=$(jq -c '.node_instance_types' "$DEPLOY_CONFIG_FILE")

echo "Terraform variables:"
echo "  Region: $TF_VAR_region"
echo "  Target Account: $TARGET_ACCOUNT_ID"
echo "  Management ID: $TF_VAR_management_id"
echo "  Regional AWS Account: $TF_VAR_regional_aws_account_id"
echo "  Enable Bastion: $TF_VAR_enable_bastion"
echo "  Node Instance Types: $TF_VAR_node_instance_types"
echo "  App Code: $TF_VAR_app_code"
echo "  Service Phase: $TF_VAR_service_phase"
echo "  Cost Center: $TF_VAR_cost_center"
echo "  Owner: $TF_VAR_owner"
echo "  Organization: $TF_VAR_organization"
echo "  App: $TF_VAR_app"
echo "  Repository URL: $TF_VAR_repository_url"
echo "  Repository Branch: $TF_VAR_repository_branch"
echo ""

export REGION_DEPLOYMENT=$(jq -r '.region' "$DEPLOY_CONFIG_FILE")
echo "Extracted REGION_DEPLOYMENT from config: $REGION_DEPLOYMENT"
export ENVIRONMENT="${ENVIRONMENT:-staging}"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

cd terraform/config/management-cluster
terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}" \
    -backend-config="use_lockfile=true"

set +e
terraform "${TERRAFORM_ACTION}" -auto-approve
TERRAFORM_STATUS=$?
set -e

if [ $TERRAFORM_STATUS -ne 0 ]; then
    echo "Infrastructure action failed with exit code $TERRAFORM_STATUS"
    exit $TERRAFORM_STATUS
fi

# Clean up temp cert files
rm -f "${TF_VAR_maestro_agent_cert_file:-}" "${TF_VAR_maestro_agent_config_file:-}"

if [ "${DELETE_FLAG}" == "true" ]; then
     echo "Management cluster destroyed successfully."
else
     echo "Management cluster provisioned successfully."
fi
