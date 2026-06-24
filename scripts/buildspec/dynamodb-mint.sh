#!/usr/bin/env bash
# Provision or destroy kube-applier DynamoDB tables in the RC account for one MC.
# Called from: terraform/config/pipeline-management-cluster/buildspec-dynamodb-mint.yml
#
# Runs in parallel with iot-mint.sh as part of the Mint-IoT pipeline stage.
# Like iot-mint, this runs in the RC account because DynamoDB tables live there.
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

# Resolve REGIONAL_ID from RC deploy config if not already set
if [ -z "${REGIONAL_ID:-}" ]; then
    RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json"
    if [ -f "$RC_CONFIG_FILE" ]; then
        REGIONAL_ID=$(jq -r '.regional_id' "$RC_CONFIG_FILE")
    else
        echo "ERROR: Cannot determine REGIONAL_ID — not set and RC config not found: $RC_CONFIG_FILE" >&2
        exit 1
    fi
fi

# Switch to RC account — DynamoDB tables live there
use_rc_account

RC_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DYNAMODB_STATE_BUCKET="terraform-state-${RC_ACCOUNT_ID}-${TARGET_REGION}"
DYNAMODB_STATE_KEY="kube-applier-dynamodb/${CLUSTER_ID}.tfstate"

# Read delete flag from config (GitOps-driven deletion)
MC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-management-cluster-${MANAGEMENT_ID}-inputs/terraform.json"
if [ ! -f "$MC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $MC_CONFIG_FILE" >&2
    exit 1
fi
DELETE_FLAG=$(jq -r '.delete // false' "$MC_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

# enable_pitr: true for non-ephemeral environments
ENABLE_PITR="false"
if [[ "${ENVIRONMENT}" != "ephemeral" ]]; then
    ENABLE_PITR="true"
fi

# Generate temporary tfvars
TEMP_TFVARS=$(mktemp /tmp/dynamodb-mint-XXXXXX.tfvars)
cat > "$TEMP_TFVARS" <<TFVARS
management_cluster_id = "${CLUSTER_ID}"
regional_id           = "${REGIONAL_ID}"
enable_pitr           = ${ENABLE_PITR}
app_code              = "${APP_CODE}"
service_phase         = "${SERVICE_PHASE}"
cost_center           = "${COST_CENTER}"
TFVARS

# Run DynamoDB provisioning with persistent remote state in RC account
cd terraform/config/kube-applier-dynamodb-provisioning

terraform init -reconfigure \
    -backend-config="bucket=${DYNAMODB_STATE_BUCKET}" \
    -backend-config="key=${DYNAMODB_STATE_KEY}" \
    -backend-config="region=${TARGET_REGION}" \
    -backend-config="use_lockfile=true"

if [ "${DELETE_FLAG}" == "true" ]; then
    terraform destroy -var-file="$TEMP_TFVARS" -auto-approve
else
    terraform plan -var-file="$TEMP_TFVARS" -out=tfplan
    terraform apply tfplan
    rm -f tfplan
fi

rm -f "$TEMP_TFVARS"
