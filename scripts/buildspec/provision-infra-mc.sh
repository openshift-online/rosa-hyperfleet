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

# ── Phase 1: Read OIDC outputs from RC account ─────────────────────────────
if [ "${DELETE_FLAG}" == "true" ]; then
    # Provide placeholders so terraform destroy can pass the planning phase.
    export TF_VAR_oidc_cloudfront_domain="placeholder"
    export TF_VAR_oidc_bucket_name="placeholder"
    export TF_VAR_oidc_bucket_arn="arn:aws:s3:::placeholder"
    export TF_VAR_oidc_bucket_region="us-east-1"
    export TF_VAR_zoa_lambda_ecr_url="000000000000.dkr.ecr.us-east-1.amazonaws.com/placeholder"
    export TF_VAR_zoa_access_lambda_role_arn="arn:aws:iam::000000000000:role/destroy-placeholder"
else
    # Assume child admin role in RC account to access state bucket (scoped access instead of org-wide).
    _resolve_rc_account
    RESOLVED_REGIONAL_ACCOUNT_ID="${_RESOLVED_RC_ACCOUNT_ID}"
    echo "Assuming ${CHILD_ADMIN_ROLE_NAME} in RC account ${RESOLVED_REGIONAL_ACCOUNT_ID} for state access..."
    _rc_creds=$(aws sts assume-role \
        --role-arn "arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${CHILD_ADMIN_ROLE_NAME}" \
        --role-session-name "mc-read-rc-state-${MANAGEMENT_ID}" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text)

    _RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "regional")
    export DNS_ZONE_OPERATOR_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-dns-zone-operator"
    export OIDC_WRITER_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-oidc-writer"
    export OIDC_KEY_READER_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-oidc-key-reader"

    # Read OIDC outputs from RC terraform state. RC and MC pipelines run in
    # parallel — retry until the outputs appear or we timeout (45 min).
    _RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
    _RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
    _RC_TF_DIR="terraform/config/regional-cluster"
    AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') \
    AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') \
    AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') \
    terraform -chdir="$_RC_TF_DIR" init -reconfigure \
        -backend-config="bucket=${_RC_STATE_BUCKET}" \
        -backend-config="key=${_RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null 2>&1

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
        TF_VAR_oidc_cloudfront_domain=$(AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') terraform -chdir="$_RC_TF_DIR" output -raw oidc_cloudfront_domain 2>/dev/null || true)
        TF_VAR_oidc_bucket_name=$(AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') terraform -chdir="$_RC_TF_DIR" output -raw oidc_bucket_name 2>/dev/null || true)
        TF_VAR_oidc_bucket_arn=$(AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') terraform -chdir="$_RC_TF_DIR" output -raw oidc_bucket_arn 2>/dev/null || true)
        TF_VAR_oidc_bucket_region=$(AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') terraform -chdir="$_RC_TF_DIR" output -raw oidc_bucket_region 2>/dev/null || true)
        TF_VAR_rhobs_api_url=$(AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') terraform -chdir="$_RC_TF_DIR" output -raw rhobs_api_url 2>/dev/null || true)
        TF_VAR_zoa_kms_key_arn=$(AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') terraform -chdir="$_RC_TF_DIR" output -raw zoa_kms_key_arn 2>/dev/null | grep -E '^arn:' || true)
        TF_VAR_zoa_access_lambda_role_arn=$(AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') terraform -chdir="$_RC_TF_DIR" output -raw zoa_access_lambda_role_arn 2>/dev/null | grep -E '^arn:' || true)
        if [ -n "${TF_VAR_oidc_cloudfront_domain}" ] && \
           [ -n "${TF_VAR_oidc_bucket_name}" ] && \
           [ -n "${TF_VAR_oidc_bucket_arn}" ] && \
           [ -n "${TF_VAR_oidc_bucket_region}" ] && \
           [ -n "${TF_VAR_rhobs_api_url}" ] && \
           [ -n "${TF_VAR_zoa_kms_key_arn}" ] && \
           [ -n "${TF_VAR_zoa_access_lambda_role_arn}" ]; then
            break
        fi
        echo "RC outputs not ready (attempt ${_OIDC_RETRY_COUNT}/${_OIDC_MAX_RETRIES}), retrying in ${_OIDC_RETRY_DELAY}s..."
        sleep "$_OIDC_RETRY_DELAY"
    done
    if [ -z "${TF_VAR_oidc_cloudfront_domain}" ] || \
       [ -z "${TF_VAR_oidc_bucket_name}" ] || \
       [ -z "${TF_VAR_oidc_bucket_arn}" ] || \
       [ -z "${TF_VAR_oidc_bucket_region}" ] || \
       [ -z "${TF_VAR_rhobs_api_url}" ] || \
       [ -z "${TF_VAR_zoa_kms_key_arn}" ] || \
       [ -z "${TF_VAR_zoa_access_lambda_role_arn}" ]; then
        echo "ERROR: RC outputs missing after $((_OIDC_MAX_RETRIES * _OIDC_RETRY_DELAY / 60))+ minutes (need OIDC, rhobs_api_url, zoa_kms_key_arn, zoa_access_lambda_role_arn)" >&2
        exit 1
    fi
    export TF_VAR_oidc_cloudfront_domain TF_VAR_oidc_bucket_name TF_VAR_oidc_bucket_arn TF_VAR_oidc_bucket_region TF_VAR_rhobs_api_url

    # ZOA outputs bucket ARN — validate output looks like an ARN to avoid
    # capturing terraform warnings as the value (non-ASCII chars break IAM policies)
    export TF_VAR_zoa_outputs_bucket_arn=$(cd "$_RC_TF_DIR" && terraform output -raw zoa_bucket_arn 2>/dev/null | grep -E '^arn:' || echo "")

    export TF_VAR_zoa_kms_key_arn
    export TF_VAR_zoa_access_lambda_role_arn

    # ZOA Lambda data-layer outputs (DynamoDB tables + uploader role in RC account)
    export TF_VAR_zoa_table_name=$(cd "$_RC_TF_DIR" && terraform output -raw zoa_table_name 2>/dev/null || echo "")
    export TF_VAR_zoa_audit_table_name=$(cd "$_RC_TF_DIR" && terraform output -raw zoa_audit_table_name 2>/dev/null || echo "")
    export TF_VAR_zoa_sessions_table_name=$(cd "$_RC_TF_DIR" && terraform output -raw zoa_sessions_table_name 2>/dev/null || echo "")
    export TF_VAR_zoa_uploader_role_arn=$(cd "$_RC_TF_DIR" && terraform output -raw zoa_uploader_role_arn 2>/dev/null | grep -E '^arn:' || echo "")
    export TF_VAR_zoa_data_access_role_arn=$(AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') terraform -chdir="$_RC_TF_DIR" output -raw zoa_data_access_role_arn 2>/dev/null | grep -E '^arn:' || echo "")
fi

# ── Phase 1b: ZOA Lambda image reference ──────────────────────────────────────
# Lambda image lives in RC's ECR (cross-account pull via OU policy).
# Runner image is pulled directly from Quay by K8s nodes.
if [ "${DELETE_FLAG}" != "true" ]; then
    export TF_VAR_zoa_lambda_ecr_url=$(cd "$_RC_TF_DIR" && terraform output -raw zoa_lambda_ecr_url 2>/dev/null || echo "")
fi

# ZOA image tags and source registries — from MC deploy config (same pins as RC)
export TF_VAR_zoa_lambda_image_tag=$(jq -r '.zoa_lambda_image_tag // ""' "$DEPLOY_CONFIG_FILE")
export TF_VAR_zoa_runner_image_tag=$(jq -r '.zoa_runner_image_tag // ""' "$DEPLOY_CONFIG_FILE")
export TF_VAR_zoa_runner_source_image=$(jq -r '.zoa_runner_source_image // ""' "$DEPLOY_CONFIG_FILE")
# Boundary ECS pulls Quay directly (no RC ECR mirror); compose full ref for TF_VAR_zoa_boundary_image.
_zoa_boundary_image_tag=$(jq -r '.zoa_boundary_image_tag // ""' "$DEPLOY_CONFIG_FILE")
_zoa_boundary_source_image=$(jq -r '.zoa_boundary_source_image // ""' "$DEPLOY_CONFIG_FILE")
if [ -z "${_zoa_boundary_image_tag}" ] || [ -z "${_zoa_boundary_source_image}" ]; then
    echo "ERROR: zoa_boundary_image_tag and zoa_boundary_source_image must be set in deploy config (full ZOA stack is always deployed)" >&2
    exit 1
fi
export TF_VAR_zoa_boundary_image="${_zoa_boundary_source_image}:${_zoa_boundary_image_tag}"
export TF_VAR_zoa_boundary_session_idle_timeout_seconds=$(jq -r '.zoa_boundary_session_idle_timeout_seconds // 3600' "$DEPLOY_CONFIG_FILE")
export TF_VAR_zoa_lambda_api_concurrency=$(jq -r '.zoa_lambda_api_concurrency' "$DEPLOY_CONFIG_FILE")
export TF_VAR_zoa_lambda_worker_concurrency=$(jq -r '.zoa_lambda_worker_concurrency' "$DEPLOY_CONFIG_FILE")
export TF_VAR_worker_node_ami_id=$(jq -r '.worker_node_ami_id // ""' "$DEPLOY_CONFIG_FILE")

# Deployment id for /zoa/targets/<deployment>/<cluster> and central /zoa/deployments/* (rendered in deploy JSON).
export TF_VAR_zoa_deployment_name=$(jq -r '.zoa_deployment_name // empty' "$DEPLOY_CONFIG_FILE")
if [ -z "${TF_VAR_zoa_deployment_name}" ]; then
    export TF_VAR_zoa_deployment_name=$(jq -r '.deployment_name // empty' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "")
fi
if [ -z "${TF_VAR_zoa_deployment_name}" ]; then
    echo "ERROR: zoa_deployment_name not set in MC deploy config or RC deployment_name" >&2
    exit 1
fi

# ── Phase 2: Apply/Destroy MC infrastructure ─────────────────────────────────
# MC ZOA target SSM: separate pipeline stage (buildspec-provision-mc-zoa-target-ssm.yml).
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
if [ -n "${OIDC_KEY_READER_ROLE_ARN:-}" ]; then
    export TF_VAR_oidc_key_reader_role_arn="${OIDC_KEY_READER_ROLE_ARN}"
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
terraform "${TERRAFORM_ACTION}" -auto-approve
TERRAFORM_STATUS=$?
set -e

if [ $TERRAFORM_STATUS -ne 0 ]; then
    exit $TERRAFORM_STATUS
fi
