#!/usr/bin/env bash
# ZOA MC target in RC SSM (/zoa/targets/<deployment>/<cluster>).
# Called from provision-infra-mc.sh (apply|destroy); not a separate pipeline stage.
# Pattern: same as provision-kube-applier-dynamodb.sh (use_rc_account + Terraform in RC).
set -euo pipefail

TERRAFORM_ACTION="${1:?usage: provision-mc-zoa-target-ssm.sh apply|destroy}"
if [ "${TERRAFORM_ACTION}" != "apply" ] && [ "${TERRAFORM_ACTION}" != "destroy" ]; then
    echo "ERROR: action must be apply or destroy" >&2
    exit 1
fi

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

_zoa_deployment_name=$(jq -r '.zoa_deployment_name // empty' "$DEPLOY_CONFIG_FILE")
if [ -z "${_zoa_deployment_name}" ]; then
    _zoa_deployment_name=$(jq -r '.deployment_name // empty' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "")
fi
if [ -z "${_zoa_deployment_name}" ]; then
    echo "ERROR: zoa_deployment_name not set in MC deploy config or RC deployment_name" >&2
    exit 1
fi

_eph_prefix=$(jq -r '.eph_prefix // empty' "$DEPLOY_CONFIG_FILE")
_targets_ssm_prefix="/zoa/targets/${_zoa_deployment_name}"
_ssm_param_name="${_targets_ssm_prefix}/${CLUSTER_ID}"

echo "MC ${MANAGEMENT_ID}: mc-zoa-target-ssm terraform ${TERRAFORM_ACTION} in RC account ${RESOLVED_REGIONAL_ACCOUNT_ID}/${TARGET_REGION}"

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_MC_TF_DIR="${_REPO_ROOT}/terraform/config/management-cluster"

export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_cluster_id="${CLUSTER_ID}"
export TF_VAR_deployment_name="${_zoa_deployment_name}"
export TF_VAR_targets_ssm_prefix="${_targets_ssm_prefix}"
export TF_VAR_mc_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_environment="${ENVIRONMENT:-staging}"
export TF_VAR_eph_prefix="${_eph_prefix}"

if [ "${TERRAFORM_ACTION}" == "apply" ]; then
    use_mc_account
    export TF_VAR_vpc_id
    TF_VAR_vpc_id=$(terraform -chdir="${_MC_TF_DIR}" output -raw vpc_id)
    export TF_VAR_private_subnet_ids
    TF_VAR_private_subnet_ids=$(terraform -chdir="${_MC_TF_DIR}" output -json private_subnets | jq -r 'join(",")')
    export TF_VAR_security_group_id
    TF_VAR_security_group_id=$(terraform -chdir="${_MC_TF_DIR}" output -raw zoa_boundary_security_group_id)
    export TF_VAR_ecs_cluster_arn
    TF_VAR_ecs_cluster_arn=$(terraform -chdir="${_MC_TF_DIR}" output -raw zoa_boundary_ecs_cluster_arn)
    export TF_VAR_task_definition_arn
    TF_VAR_task_definition_arn=$(terraform -chdir="${_MC_TF_DIR}" output -raw zoa_boundary_task_definition_arn)
    export TF_VAR_function_url
    TF_VAR_function_url=$(terraform -chdir="${_MC_TF_DIR}" output -raw zoa_api_function_url)
else
    export TF_VAR_vpc_id="destroy-placeholder"
    export TF_VAR_private_subnet_ids="subnet-placeholder"
    export TF_VAR_security_group_id="sg-placeholder"
    export TF_VAR_ecs_cluster_arn="arn:aws:ecs:${TARGET_REGION}:${TARGET_ACCOUNT_ID}:cluster/placeholder"
    export TF_VAR_task_definition_arn="arn:aws:ecs:${TARGET_REGION}:${TARGET_ACCOUNT_ID}:task-definition/placeholder:1"
    export TF_VAR_function_url="https://placeholder.lambda-url.${TARGET_REGION}.on.aws/"
fi

use_rc_account

export TF_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="mc-zoa-target-ssm/${CLUSTER_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

cd terraform/config/mc-zoa-target-ssm-provisioning
terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}" \
    -backend-config="use_lockfile=true"

if [ "${TERRAFORM_ACTION}" == "destroy" ]; then
    if ! terraform state show aws_ssm_parameter.target >/dev/null 2>&1; then
        terraform import aws_ssm_parameter.target "${_ssm_param_name}" 2>/dev/null \
            || echo "No legacy SSM parameter to import (ok)"
    fi
fi

set +e
terraform "${TERRAFORM_ACTION}" -auto-approve
TERRAFORM_STATUS=$?
set -e

if [ $TERRAFORM_STATUS -ne 0 ]; then
    exit $TERRAFORM_STATUS
fi
