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

    # Construct dns_zone_operator_role_arn deterministically (avoids reading RC state)
    _RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "regional")
    export DNS_ZONE_OPERATOR_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-dns-zone-operator"
    echo "  DNS Zone Operator Role ARN: ${DNS_ZONE_OPERATOR_ROLE_ARN}"

    # Read RHOBS API URL and OIDC outputs from RC terraform state.
    # The RC and MC pipelines run in parallel; the RC apply can take 30-40
    # minutes. Retry until the OIDC outputs appear in the RC state or we
    # exhaust the timeout.
    echo "Reading outputs from RC terraform state..."
    _RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
    _RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
    _RC_TF_DIR="terraform/config/regional-cluster"
    (cd "$_RC_TF_DIR" && terraform init -reconfigure \
        -backend-config="bucket=${_RC_STATE_BUCKET}" \
        -backend-config="key=${_RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null 2>&1)
    export TF_VAR_rhobs_api_url=$(cd "$_RC_TF_DIR" && terraform output -raw rhobs_api_url 2>/dev/null || echo "")
    echo "  RHOBS API URL:  ${TF_VAR_rhobs_api_url:-<not available>}"

    # Retry loop: the RC pipeline may still be running when the MC pipeline
    # starts. Wait up to 45 minutes (90 × 30s) for the OIDC outputs to be
    # written to the RC terraform state backend.
    _OIDC_MAX_RETRIES=90
    _OIDC_RETRY_DELAY=30
    _OIDC_RETRY_COUNT=0
    TF_VAR_oidc_cloudfront_domain=""
    TF_VAR_oidc_bucket_name=""
    TF_VAR_oidc_bucket_arn=""
    TF_VAR_oidc_bucket_region=""
    while [ $_OIDC_RETRY_COUNT -lt $_OIDC_MAX_RETRIES ]; do
        _OIDC_RETRY_COUNT=$((_OIDC_RETRY_COUNT + 1))
        TF_VAR_oidc_cloudfront_domain=$(cd "$_RC_TF_DIR" && terraform output -raw oidc_cloudfront_domain 2>/dev/null || true)
        TF_VAR_oidc_bucket_name=$(cd "$_RC_TF_DIR" && terraform output -raw oidc_bucket_name 2>/dev/null || true)
        TF_VAR_oidc_bucket_arn=$(cd "$_RC_TF_DIR" && terraform output -raw oidc_bucket_arn 2>/dev/null || true)
        TF_VAR_oidc_bucket_region=$(cd "$_RC_TF_DIR" && terraform output -raw oidc_bucket_region 2>/dev/null || true)
        if [ -n "${TF_VAR_oidc_cloudfront_domain}" ] && \
           [ -n "${TF_VAR_oidc_bucket_name}" ] && \
           [ -n "${TF_VAR_oidc_bucket_arn}" ] && \
           [ -n "${TF_VAR_oidc_bucket_region}" ]; then
            break
        fi
        echo "  OIDC outputs not yet available in RC state (attempt ${_OIDC_RETRY_COUNT}/${_OIDC_MAX_RETRIES}) — RC pipeline may still be running. Retrying in ${_OIDC_RETRY_DELAY}s..."
        sleep "$_OIDC_RETRY_DELAY"
    done
    if [ -z "${TF_VAR_oidc_cloudfront_domain}" ] || \
       [ -z "${TF_VAR_oidc_bucket_name}" ] || \
       [ -z "${TF_VAR_oidc_bucket_arn}" ] || \
       [ -z "${TF_VAR_oidc_bucket_region}" ]; then
        echo "ERROR: OIDC outputs still missing from RC terraform state after $((_OIDC_MAX_RETRIES * _OIDC_RETRY_DELAY / 60))+ minutes." >&2
        echo "  Ensure the RC pipeline completed successfully before the MC pipeline times out." >&2
        exit 1
    fi
    export TF_VAR_oidc_cloudfront_domain
    export TF_VAR_oidc_bucket_name
    export TF_VAR_oidc_bucket_arn
    export TF_VAR_oidc_bucket_region
    echo "  OIDC CloudFront: ${TF_VAR_oidc_cloudfront_domain}"
    echo "  OIDC Bucket:     ${TF_VAR_oidc_bucket_name}"
    echo "  OIDC Bucket ARN: ${TF_VAR_oidc_bucket_arn}"
    echo "  OIDC Region:     ${TF_VAR_oidc_bucket_region}"
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

if [ -n "${DNS_ZONE_OPERATOR_ROLE_ARN:-}" ]; then
    export TF_VAR_dns_zone_operator_role_arn="${DNS_ZONE_OPERATOR_ROLE_ARN}"
fi

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