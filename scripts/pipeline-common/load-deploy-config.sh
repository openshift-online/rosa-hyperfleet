#!/usr/bin/env bash
#
# load-deploy-config.sh - Load terraform variables from deploy/ JSON files
#
# Reads configuration directly from the rendered deploy/ JSON files instead of
# relying on CodeBuild environment variables. This decouples terraform variable
# changes from the pipeline provisioner — changing a var in config.yaml only
# requires re-running render.py and pushing, without re-provisioning pipelines.
#
# Usage:
#   source scripts/pipeline-common/load-deploy-config.sh regional
#   source scripts/pipeline-common/load-deploy-config.sh management
#
# Required environment variables (set by CodeBuild):
#   ENVIRONMENT    - Target environment (e.g., integration, staging)
#   TARGET_REGION  - AWS region (e.g., us-east-1)
#   REGIONAL_ID    - Regional cluster identifier (for regional mode)
#   MANAGEMENT_ID  - Management cluster identifier (for management mode)
#
# Exports:
#   DEPLOY_CONFIG_FILE        - Path to the JSON config file
#   APP_CODE                  - Application code for tagging
#   SERVICE_PHASE             - Service phase (dev/staging/prod)
#   COST_CENTER               - Cost center for billing
#   OWNER                     - Resource owner team identifier
#   ORGANIZATION              - Organization name for cost attribution
#   ENABLE_BASTION            - "true" or "false"
#   ENVIRONMENT_DOMAIN        - Environment domain (from pipeline-provisioner-inputs/terraform.json)
#   For management mode only:
#     CLUSTER_ID              - Management cluster identifier
#     REGIONAL_AWS_ACCOUNT_ID - Resolved RC account ID (SSM-aware)

set -euo pipefail

# parseBool JQ_FILTER [DEFAULT] FILE
# Reads a boolean field from a JSON file via jq. Returns "true" or "false".
# Exits 9 if the value is not a recognised boolean (true/false/1/0/null).
# When the field is null/missing, DEFAULT is used ("false" if omitted).
parseBool() {
    local _filter="$1" _default="${2:-false}" _file="$3"
    local _raw=""
    _raw=$(jq -r "if $_filter == null then \"__null__\" else $_filter end" "$_file") || return $?
    case "$_raw" in
        true|1)  echo "true" ;;
        false|0) echo "false" ;;
        __null__) echo "$_default" ;;
        *)
            echo "ERROR: parseBool: expected boolean for '$_filter' in $_file, got '$_raw'" >&2
            exit 9
            ;;
    esac
}

_DEPLOY_MODE="${1:-}"
if [[ -z "$_DEPLOY_MODE" ]]; then
    echo "ERROR: load-deploy-config.sh requires an argument: 'regional' or 'management'" >&2
    exit 1
fi

ENVIRONMENT="${ENVIRONMENT:-staging}"

if [[ "$_DEPLOY_MODE" == "regional" ]]; then
    DEPLOY_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json"
elif [[ "$_DEPLOY_MODE" == "management" ]]; then
    DEPLOY_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-management-cluster-${MANAGEMENT_ID}-inputs/terraform.json"
else
    echo "ERROR: load-deploy-config.sh: unknown mode '$_DEPLOY_MODE' (expected 'regional' or 'management')" >&2
    exit 1
fi

if [ ! -f "$DEPLOY_CONFIG_FILE" ]; then
    echo "ERROR: Deploy config not found: $DEPLOY_CONFIG_FILE" >&2
    exit 1
fi

echo "Loading deploy config from: $DEPLOY_CONFIG_FILE"

# Extract terraform variables from the JSON config
APP_CODE=$(jq -r '.app_code // "infra"' "$DEPLOY_CONFIG_FILE")
SERVICE_PHASE=$(jq -r '.service_phase // "dev"' "$DEPLOY_CONFIG_FILE")
COST_CENTER=$(jq -r '.cost_center // "000"' "$DEPLOY_CONFIG_FILE")
OWNER=$(jq -r '.owner // "placeholder"' "$DEPLOY_CONFIG_FILE")
ORGANIZATION=$(jq -r '.organization // "placeholder"' "$DEPLOY_CONFIG_FILE")
APP=$(jq -r '.app // "rosa-regionality"' "$DEPLOY_CONFIG_FILE")

ENABLE_BASTION=$(parseBool '.enable_bastion' false "$DEPLOY_CONFIG_FILE")

# Read environment domain from pipeline-provisioner-inputs/terraform.json
_ENV_JSON="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-provisioner-inputs/terraform.json"
if [ -f "$_ENV_JSON" ]; then
    ENVIRONMENT_DOMAIN=$(jq -r '.domain // empty' "$_ENV_JSON")
else
    ENVIRONMENT_DOMAIN=""
fi

# Management-mode specific: resolve CLUSTER_ID and REGIONAL_AWS_ACCOUNT_ID
if [[ "$_DEPLOY_MODE" == "management" ]]; then
    CLUSTER_ID=$(jq -r '.management_id // ""' "$DEPLOY_CONFIG_FILE")
    REGIONAL_AWS_ACCOUNT_ID=$(jq -r '.regional_aws_account_id // ""' "$DEPLOY_CONFIG_FILE")

    # Resolve SSM parameter references
    if [[ "$REGIONAL_AWS_ACCOUNT_ID" =~ ^ssm:// ]]; then
        _SSM_PARAM_NAME="${REGIONAL_AWS_ACCOUNT_ID#ssm://}"
        echo "Resolving SSM parameter: $_SSM_PARAM_NAME in region ${TARGET_REGION}"
        REGIONAL_AWS_ACCOUNT_ID=$(aws ssm get-parameter \
            --name "$_SSM_PARAM_NAME" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${TARGET_REGION}")
        echo "Resolved regional account ID: $REGIONAL_AWS_ACCOUNT_ID"
    fi

    if [[ -z "$REGIONAL_AWS_ACCOUNT_ID" ]]; then
        echo "ERROR: regional_aws_account_id must be provided in $DEPLOY_CONFIG_FILE" >&2
        exit 1
    fi

    export CLUSTER_ID
    export REGIONAL_AWS_ACCOUNT_ID
fi

export DEPLOY_CONFIG_FILE
export APP_CODE
export SERVICE_PHASE
export COST_CENTER
export OWNER
export ORGANIZATION
export APP
export ENABLE_BASTION
export ENVIRONMENT_DOMAIN

echo "  APP_CODE=$APP_CODE SERVICE_PHASE=$SERVICE_PHASE COST_CENTER=$COST_CENTER OWNER=$OWNER ORGANIZATION=$ORGANIZATION  APP=$APP"
echo "  ENABLE_BASTION=$ENABLE_BASTION"
[ -n "${ENVIRONMENT_DOMAIN:-}" ] && echo "  ENVIRONMENT_DOMAIN=$ENVIRONMENT_DOMAIN"
[[ "$_DEPLOY_MODE" == "management" ]] && echo "  CLUSTER_ID=$CLUSTER_ID REGIONAL_AWS_ACCOUNT_ID=$REGIONAL_AWS_ACCOUNT_ID"
echo ""
