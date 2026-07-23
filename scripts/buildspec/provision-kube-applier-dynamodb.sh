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

# ── Read MC messaging outputs from management-cluster state ────────────────
# The mc-messaging module (specs SQS queue + status SNS topic) is provisioned
# by the MC management-cluster pipeline step, which may run in parallel with
# this step. Retry until the outputs appear or we time out (45 min), matching
# the pattern used for OIDC outputs in provision-infra-mc.sh.
#
# On destroy, skip the read and pass empty strings so the rc-messaging module
# is cleanly removed without blocking on stale MC outputs.
if [ "${DELETE_FLAG}" != "true" ]; then
    _MC_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
    _MC_STATE_KEY="management-cluster/${CLUSTER_ID}.tfstate"
    _MC_TF_DIR="terraform/config/management-cluster"

    # Init the MC state backend (read-only; we only run `terraform output`)
    (cd "$_MC_TF_DIR" && terraform init -reconfigure \
        -backend-config="bucket=${_MC_STATE_BUCKET}" \
        -backend-config="key=${_MC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null 2>&1)

    _MSG_MAX_RETRIES=90
    _MSG_RETRY_DELAY=30
    _MSG_RETRY_COUNT=0
    TF_VAR_mc_specs_queue_arn=""
    TF_VAR_mc_status_sns_topic_arn=""
    while [ $_MSG_RETRY_COUNT -lt $_MSG_MAX_RETRIES ]; do
        _MSG_RETRY_COUNT=$((_MSG_RETRY_COUNT + 1))
        TF_VAR_mc_specs_queue_arn=$(cd "$_MC_TF_DIR" && terraform output -raw kube_applier_specs_queue_arn 2>/dev/null || true)
        TF_VAR_mc_status_sns_topic_arn=$(cd "$_MC_TF_DIR" && terraform output -raw kube_applier_status_topic_arn 2>/dev/null || true)
        if [ -n "${TF_VAR_mc_specs_queue_arn}" ] && [ -n "${TF_VAR_mc_status_sns_topic_arn}" ]; then
            break
        fi
        echo "MC messaging outputs not ready (attempt ${_MSG_RETRY_COUNT}/${_MSG_MAX_RETRIES}), retrying in ${_MSG_RETRY_DELAY}s..."
        sleep "$_MSG_RETRY_DELAY"
    done
    if [ -z "${TF_VAR_mc_specs_queue_arn}" ] || [ -z "${TF_VAR_mc_status_sns_topic_arn}" ]; then
        echo "INFO: MC messaging outputs missing after $((_MSG_MAX_RETRIES * _MSG_RETRY_DELAY / 60))+ minutes — rc-messaging module will be skipped."
        TF_VAR_mc_specs_queue_arn=""
        TF_VAR_mc_status_sns_topic_arn=""
    fi
    export TF_VAR_mc_specs_queue_arn TF_VAR_mc_status_sns_topic_arn
fi

# ── Terraform apply ────────────────────────────────────────────────────────
_RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_BUCKET="${_RC_STATE_BUCKET}"
export TF_STATE_KEY="kube-applier-dynamodb/${CLUSTER_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_mc_name="${CLUSTER_ID}"
export TF_VAR_mc_aws_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_rc_id="${_RC_REGIONAL_ID}"
TF_VAR_enable_pitr=$(parseBool '.kube_applier_dynamodb_enable_pitr' false "$DEPLOY_CONFIG_FILE")
export TF_VAR_enable_pitr
TF_VAR_operator_replica_count=$(jq -r '.operator_replica_count // 3' "$DEPLOY_CONFIG_FILE")
export TF_VAR_operator_replica_count
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
