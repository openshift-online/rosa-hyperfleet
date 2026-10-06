#!/usr/bin/env bash
# Provision or destroy Management Cluster infrastructure.
# Called from: terraform/config/pipeline-management-cluster/buildspec-provision-infra.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh
source scripts/pipeline-common/terraform-lib.sh

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

    # RC and MC pipelines run in parallel — wait for OIDC outputs to appear.
    # rhobs_api_url is NOT consumed by MC terraform (only re-emitted at outputs.tf);
    # bootstrap-argocd-mc.sh already polls it before ArgoCD bootstrap.

    # Set RC credentials for tf_wait_for_outputs (library reads terraform state)
    export AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}')

    # Wait up to 45 minutes (90 attempts * 30s) for RC OIDC outputs
    tf_wait_for_outputs \
        "$_RC_TF_DIR" \
        90 \
        30 \
        oidc_cloudfront_domain \
        oidc_bucket_name \
        oidc_bucket_arn \
        oidc_bucket_region || {
        echo "ERROR: Failed to read RC OIDC outputs" >&2
        exit 1
    }
    # TF_VAR_* variables auto-exported by tf_wait_for_outputs

    # ZOA outputs - read with ARN validation where applicable
    TF_VAR_zoa_outputs_bucket_arn=$(tf_read_output "$_RC_TF_DIR" zoa_bucket_arn '^arn:') || true
    export TF_VAR_zoa_outputs_bucket_arn

    TF_VAR_zoa_kms_key_arn=$(tf_read_output "$_RC_TF_DIR" zoa_kms_key_arn '^arn:') || true
    export TF_VAR_zoa_kms_key_arn

    # ZOA Lambda data-layer outputs (DynamoDB tables + uploader role in RC account)
    TF_VAR_zoa_table_name=$(tf_read_output "$_RC_TF_DIR" zoa_table_name) || true
    export TF_VAR_zoa_table_name

    TF_VAR_zoa_table_arn=$(tf_read_output "$_RC_TF_DIR" zoa_table_arn '^arn:') || true
    export TF_VAR_zoa_table_arn

    TF_VAR_zoa_audit_table_name=$(tf_read_output "$_RC_TF_DIR" zoa_audit_table_name) || true
    export TF_VAR_zoa_audit_table_name

    TF_VAR_zoa_audit_table_arn=$(tf_read_output "$_RC_TF_DIR" zoa_audit_table_arn '^arn:') || true
    export TF_VAR_zoa_audit_table_arn

    TF_VAR_zoa_uploader_role_arn=$(tf_read_output "$_RC_TF_DIR" zoa_uploader_role_arn '^arn:') || true
    export TF_VAR_zoa_uploader_role_arn

    TF_VAR_zoa_data_access_role_arn=$(tf_read_output "$_RC_TF_DIR" zoa_data_access_role_arn '^arn:') || true
    export TF_VAR_zoa_data_access_role_arn
fi

# ── Phase 1b: ZOA Lambda image reference ──────────────────────────────────────
# Lambda image lives in RC's ECR (cross-account pull via OU policy).
# Runner image is pulled directly from Quay by K8s nodes.
TF_VAR_zoa_lambda_ecr_url=$(tf_read_output "$_RC_TF_DIR" zoa_lambda_ecr_url) || true
export TF_VAR_zoa_lambda_ecr_url

# ZOA image tags moved to static.tfvars.json (worker_node_ami_id, worker_node_root_volume_size too)

# ── Phase 2: Apply/Destroy MC infrastructure ─────────────────────────────────
use_mc_account

export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="management-cluster/${MANAGEMENT_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

# Static vars (app_code, service_phase, cost_center, management_id) in static.tfvars.json
export TF_VAR_region="${TARGET_REGION}"
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

# enable_bastion moved to static.tfvars.json

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

# Deploy dir calculated by lib.sh as dirname of DEPLOY_CONFIG_FILE
DEPLOY_DIR=$(dirname "$DEPLOY_CONFIG_FILE")

# Initialize backend
tf_init_backend \
    terraform/config/management-cluster \
    "${TF_STATE_BUCKET}" \
    "${TF_STATE_KEY}" \
    "${TF_STATE_REGION}"

# Apply or destroy
tf_apply_with_static_vars \
    terraform/config/management-cluster \
    "${TERRAFORM_ACTION}" \
    "${DEPLOY_DIR}/static.tfvars.json"

