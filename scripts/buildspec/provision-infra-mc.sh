#!/usr/bin/env bash
# Provision or destroy Management Cluster infrastructure.
# Called from: terraform/config/pipeline-management-cluster/buildspec-provision-infra.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

# Determine terraform action
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

echo "MC ${MANAGEMENT_ID}: terraform ${TERRAFORM_ACTION} in ${TARGET_ACCOUNT_ID}/${TARGET_REGION}"

# ── Phase 1: Read IoT cert/config and OIDC outputs from RC account ───────────
if [ "${DELETE_FLAG}" == "true" ]; then
    # Provide placeholders so terraform destroy can pass the planning phase.
    export TF_VAR_maestro_agent_cert_file=$(mktemp)
    export TF_VAR_maestro_agent_config_file=$(mktemp)
    export TF_VAR_oidc_cloudfront_domain="placeholder"
    export TF_VAR_oidc_bucket_name="placeholder"
    export TF_VAR_oidc_bucket_arn="arn:aws:s3:::placeholder"
    export TF_VAR_oidc_bucket_region="us-east-1"
else
    use_rc_account
    read_iot_state "$RESOLVED_REGIONAL_ACCOUNT_ID" "$CLUSTER_ID" "$TARGET_REGION"

    _RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "regional")
    export DNS_ZONE_OPERATOR_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-dns-zone-operator"
    export OIDC_WRITER_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-oidc-writer"

    # Read OIDC outputs from RC terraform state. RC and MC pipelines run in
    # parallel — retry until the outputs appear or we timeout (45 min).
    _RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
    _RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
    _RC_TF_DIR="terraform/config/regional-cluster"
    (cd "$_RC_TF_DIR" && terraform init -reconfigure \
        -backend-config="bucket=${_RC_STATE_BUCKET}" \
        -backend-config="key=${_RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null 2>&1)

    # RC and MC pipelines run in parallel — retry until all outputs appear (up to 45 min)
    _OIDC_MAX_RETRIES=90
    _OIDC_RETRY_DELAY=30
    _OIDC_RETRY_COUNT=0
    TF_VAR_oidc_cloudfront_domain=""
    TF_VAR_oidc_bucket_name=""
    TF_VAR_oidc_bucket_arn=""
    TF_VAR_oidc_bucket_region=""
    TF_VAR_rhobs_api_url=""
    while [ $_OIDC_RETRY_COUNT -lt $_OIDC_MAX_RETRIES ]; do
        _OIDC_RETRY_COUNT=$((_OIDC_RETRY_COUNT + 1))
        TF_VAR_oidc_cloudfront_domain=$(cd "$_RC_TF_DIR" && terraform output -raw oidc_cloudfront_domain 2>/dev/null || true)
        TF_VAR_oidc_bucket_name=$(cd "$_RC_TF_DIR" && terraform output -raw oidc_bucket_name 2>/dev/null || true)
        TF_VAR_oidc_bucket_arn=$(cd "$_RC_TF_DIR" && terraform output -raw oidc_bucket_arn 2>/dev/null || true)
        TF_VAR_oidc_bucket_region=$(cd "$_RC_TF_DIR" && terraform output -raw oidc_bucket_region 2>/dev/null || true)
        TF_VAR_rhobs_api_url=$(cd "$_RC_TF_DIR" && terraform output -raw rhobs_api_url 2>/dev/null || true)
        if [ -n "${TF_VAR_oidc_cloudfront_domain}" ] && \
           [ -n "${TF_VAR_oidc_bucket_name}" ] && \
           [ -n "${TF_VAR_oidc_bucket_arn}" ] && \
           [ -n "${TF_VAR_oidc_bucket_region}" ] && \
           [ -n "${TF_VAR_rhobs_api_url}" ]; then
            break
        fi
        echo "RC outputs not ready (attempt ${_OIDC_RETRY_COUNT}/${_OIDC_MAX_RETRIES}), retrying in ${_OIDC_RETRY_DELAY}s..."
        sleep "$_OIDC_RETRY_DELAY"
    done
    if [ -z "${TF_VAR_oidc_cloudfront_domain}" ] || \
       [ -z "${TF_VAR_oidc_bucket_name}" ] || \
       [ -z "${TF_VAR_oidc_bucket_arn}" ] || \
       [ -z "${TF_VAR_oidc_bucket_region}" ] || \
       [ -z "${TF_VAR_rhobs_api_url}" ]; then
        echo "ERROR: RC outputs missing after $((_OIDC_MAX_RETRIES * _OIDC_RETRY_DELAY / 60))+ minutes" >&2
        exit 1
    fi
    export TF_VAR_oidc_cloudfront_domain TF_VAR_oidc_bucket_name TF_VAR_oidc_bucket_arn TF_VAR_oidc_bucket_region TF_VAR_rhobs_api_url

    # ZOA outputs bucket ARN
    export TF_VAR_zoa_outputs_bucket_arn=$(cd "$_RC_TF_DIR" && terraform output -raw zoa_bucket_arn 2>/dev/null || echo "")

    # ZOA KMS key ARN (optional — for S3 SSE-KMS cross-account access)
    export TF_VAR_zoa_kms_key_arn=$(cd "$_RC_TF_DIR" && terraform output -raw zoa_kms_key_arn 2>/dev/null || echo "")
fi

# ── Phase 2: Apply/Destroy MC infrastructure ─────────────────────────────────
use_mc_account

export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="management-cluster/${MANAGEMENT_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_management_id="${CLUSTER_ID:-mgmt-cluster-01}"
export TF_VAR_environment="${ENVIRONMENT:-staging}"
export TF_VAR_regional_aws_account_id="${RESOLVED_REGIONAL_ACCOUNT_ID}"

# TF_VAR_maestro_agent_cert_file and TF_VAR_maestro_agent_config_file
# are already exported by read_iot_state()

_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

if [ -z "${PLATFORM_IMAGE:-}" ]; then
    echo "ERROR: PLATFORM_IMAGE is not set" >&2
    exit 1
fi
export TF_VAR_container_image="${PLATFORM_IMAGE}"

export TF_VAR_enable_bastion="${ENABLE_BASTION}"

if [ -n "${DNS_ZONE_OPERATOR_ROLE_ARN:-}" ]; then
    export TF_VAR_dns_zone_operator_role_arn="${DNS_ZONE_OPERATOR_ROLE_ARN}"
fi
if [ -n "${OIDC_WRITER_ROLE_ARN:-}" ]; then
    export TF_VAR_oidc_writer_role_arn="${OIDC_WRITER_ROLE_ARN}"
fi

export REGION_DEPLOYMENT=$(jq -r '.region' "$DEPLOY_CONFIG_FILE")
export ENVIRONMENT="${ENVIRONMENT:-staging}"

cd terraform/config/management-cluster
terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}" \
    -backend-config="use_lockfile=true"

if [ "${TERRAFORM_ACTION}" == "apply" ] && [ -f imports.sh ]; then
    source imports.sh
fi

set +e
terraform "${TERRAFORM_ACTION}" -auto-approve -parallelism=20
TERRAFORM_STATUS=$?
set -e

if [ $TERRAFORM_STATUS -ne 0 ]; then
    exit $TERRAFORM_STATUS
fi

rm -f "${TF_VAR_maestro_agent_cert_file:-}" "${TF_VAR_maestro_agent_config_file:-}"
