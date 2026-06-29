#!/usr/bin/env bash
# Provision kube-applier DynamoDB tables and hyperfleet-operator IAM policy
# in the RC account for this Management Cluster.
# Called from: terraform/config/pipeline-management-cluster/buildspec-provision-kube-applier-dynamodb.yml
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

echo "MC ${MANAGEMENT_ID}: kube-applier-dynamodb terraform ${TERRAFORM_ACTION} in RC account ${RESOLVED_REGIONAL_ACCOUNT_ID}/${TARGET_REGION}"

# Read RC regional_id from RC deploy config
_RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json"
if [ ! -f "$_RC_CONFIG_FILE" ]; then
    echo "ERROR: RC config not found: $_RC_CONFIG_FILE" >&2
    exit 1
fi
_RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "$_RC_CONFIG_FILE")

# ── Switch to RC account ────────────────────────────────────────────────────
use_rc_account

# ── Wait for hyperfleet-operator role (created by RC pipeline) ──────────────
# The MC Deploy stage already waited for RC OIDC outputs, so the RC pipeline
# should be done or nearly done. Poll briefly as a safety net.
_RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
_RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
_RC_TF_DIR="terraform/config/regional-cluster"
(cd "$_RC_TF_DIR" && terraform init -reconfigure \
    -backend-config="bucket=${_RC_STATE_BUCKET}" \
    -backend-config="key=${_RC_STATE_KEY}" \
    -backend-config="region=${TARGET_REGION}" \
    -backend-config="use_lockfile=true" >/dev/null 2>&1)

_MAX_RETRIES=90
_RETRY_DELAY=30
_RETRY_COUNT=0
_HYPERFLEET_ROLE_ARN=""
while [ $_RETRY_COUNT -lt $_MAX_RETRIES ]; do
    _RETRY_COUNT=$((_RETRY_COUNT + 1))
    _HYPERFLEET_ROLE_ARN=$(cd "$_RC_TF_DIR" && terraform output -raw hyperfleet_operator_role_arn 2>/dev/null || true)
    if [ -n "${_HYPERFLEET_ROLE_ARN}" ]; then
        break
    fi
    echo "RC outputs not ready (attempt ${_RETRY_COUNT}/${_MAX_RETRIES}), retrying in ${_RETRY_DELAY}s..."
    sleep "$_RETRY_DELAY"
done
if [ -z "${_HYPERFLEET_ROLE_ARN}" ]; then
    echo "ERROR: hyperfleet_operator_role_arn not available after $((_MAX_RETRIES * _RETRY_DELAY / 60))+ minutes" >&2
    exit 1
fi
echo "Hyperfleet-operator role confirmed: ${_HYPERFLEET_ROLE_ARN}"

# ── Terraform apply ────────────────────────────────────────────────────────
export TF_STATE_BUCKET="${_RC_STATE_BUCKET}"
export TF_STATE_KEY="kube-applier-dynamodb/${CLUSTER_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_mc_name="${CLUSTER_ID}"
export TF_VAR_mc_aws_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_rc_id="${_RC_REGIONAL_ID}"
export TF_VAR_enable_pitr=$(parseBool '.kube_applier_dynamodb_enable_pitr' false "$DEPLOY_CONFIG_FILE")
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_environment="${ENVIRONMENT:-staging}"

cd terraform/config/kube-applier-dynamodb-provisioning
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
    exit $TERRAFORM_STATUS
fi
