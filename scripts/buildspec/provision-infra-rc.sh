#!/usr/bin/env bash
# Provision or destroy Regional Cluster infrastructure.
# Called from: terraform/config/pipeline-regional-cluster/buildspec-provision-infra.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load regional

# Save central credentials as a named AWS profile so Terraform's aws.central
# provider can access the central account after use_mc_account switches
# ambient creds to the target account.
aws configure set aws_access_key_id     "$_CENTRAL_AWS_ACCESS_KEY_ID"     --profile central
aws configure set aws_secret_access_key "$_CENTRAL_AWS_SECRET_ACCESS_KEY" --profile central
aws configure set aws_session_token     "$_CENTRAL_AWS_SESSION_TOKEN"     --profile central
aws configure set region                "${TARGET_REGION}"                --profile central
export TF_VAR_central_aws_profile="central"

# Fetch PagerDuty config if enabled
_RAW_PD=$(jq -r '.enable_pagerduty // false' "$DEPLOY_CONFIG_FILE")
if [ "$_RAW_PD" == "true" ] || [ "$_RAW_PD" == "1" ]; then
    export TF_VAR_enable_pagerduty="true"
    export TF_VAR_pagerduty_escalation_policy_id=$(jq -r '.pagerduty_escalation_policy_id // ""' "$DEPLOY_CONFIG_FILE")
    PAGERDUTY_TOKEN=$(aws secretsmanager get-secret-value \
        --secret-id "pagerduty/service-account" \
        --region us-east-1 \
        --query SecretString \
        --output text)
    export PAGERDUTY_TOKEN
fi

use_mc_account

# Configure Terraform backend (state in target account)
export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="regional-cluster/${REGIONAL_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

# Set Terraform variables
export TF_VAR_region="${TARGET_REGION}"
TF_VAR_deployment_name=$(jq -r '.deployment_name' "$DEPLOY_CONFIG_FILE")
export TF_VAR_deployment_name
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"

_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

# Build colon-delimited management clusters string: "mc01:123456789012,mc02:987654321098"
_MC_PARTS=()
_MC_INFO=$(jq -c '.management_clusters_info // []' "$DEPLOY_CONFIG_FILE")
if [[ "$_MC_INFO" != "[]" ]]; then
    for _ENTRY in $(echo "$_MC_INFO" | jq -r '.[] | @base64'); do
        _ID=$(echo "$_ENTRY" | base64 -d | jq -r '.id')
        _ACCT=$(echo "$_ENTRY" | base64 -d | jq -r '.account_id')
        if [[ "$_ACCT" =~ ^ssm:// ]]; then
            _SSM_PARAM="${_ACCT#ssm://}"
            _ACCT=$(aws ssm get-parameter --name "$_SSM_PARAM" --with-decryption \
                --query 'Parameter.Value' --output text --region "${TARGET_REGION}" 2>/dev/null || true)
        fi
        if [[ -n "$_ACCT" && -n "$_ID" ]]; then
            _MC_PARTS+=("${_ID}:${_ACCT}")
        fi
    done
fi
export TF_VAR_management_clusters=$(IFS=,; echo "${_MC_PARTS[*]}")

if [ -z "${PLATFORM_IMAGE:-}" ]; then
    echo "ERROR: PLATFORM_IMAGE is not set" >&2
    exit 1
fi
export TF_VAR_container_image="${PLATFORM_IMAGE}"

export TF_VAR_enable_bastion="${ENABLE_BASTION}"
export TF_VAR_enable_cloudtrail=$(parseBool '.enable_cloudtrail' false "$DEPLOY_CONFIG_FILE")
export TF_VAR_enable_api_custom_domain=$(parseBool '.enable_api_custom_domain' false "$DEPLOY_CONFIG_FILE")
export TF_VAR_zone_shard_count=$(jq -r '.zone_shard_count // 1' "$DEPLOY_CONFIG_FILE")
export TF_VAR_enable_sns_alerting=$(parseBool '.enable_sns_alerting' false "$DEPLOY_CONFIG_FILE")
TF_VAR_enable_sre_tools_gateway=$(parseBool '.enable_sre_tools_gateway' false "$DEPLOY_CONFIG_FILE")
export TF_VAR_enable_sre_tools_gateway
TF_VAR_enable_sre_public_access=$(parseBool '.enable_sre_public_access' false "$DEPLOY_CONFIG_FILE")
export TF_VAR_enable_sre_public_access
# SRE UI ALB allowed source CIDRs from SSM (public mode only; not committed to the repo)
if [ "$TF_VAR_enable_sre_public_access" = "true" ]; then
    TF_VAR_sre_allowed_source_cidrs=$(aws ssm get-parameter \
        --name "/infra/sre-ui-alb/allowed-source-cidrs" \
        --query 'Parameter.Value' \
        --output text \
        --region "${TARGET_REGION}" 2>/dev/null || true)
    if [ -z "${TF_VAR_sre_allowed_source_cidrs}" ]; then
        echo "ERROR: SSM parameter /infra/sre-ui-alb/allowed-source-cidrs not found in account ${TARGET_ACCOUNT_ID} region ${TARGET_REGION}" >&2
        exit 1
    fi
else
    TF_VAR_sre_allowed_source_cidrs=$(jq -c '.sre_allowed_source_cidrs // []' "$DEPLOY_CONFIG_FILE")
fi
export TF_VAR_sre_allowed_source_cidrs
TF_VAR_enable_sre_oidc_auth=$(parseBool '.enable_sre_oidc_auth' false "$DEPLOY_CONFIG_FILE")
export TF_VAR_enable_sre_oidc_auth
TF_VAR_sre_oidc_issuer_url=$(jq -r '.sre_oidc_issuer_url // "https://auth.redhat.com/auth/realms/EmployeeIDP"' "$DEPLOY_CONFIG_FILE")
export TF_VAR_sre_oidc_issuer_url

if [ "$TF_VAR_enable_sre_oidc_auth" = "true" ]; then
    TF_VAR_sre_grafana_oidc_client_id=$(jq -r '.sre_grafana_oidc_client_id // ""' "$DEPLOY_CONFIG_FILE")
    export TF_VAR_sre_grafana_oidc_client_id
    TF_VAR_sre_argocd_oidc_client_id=$(jq -r '.sre_argocd_oidc_client_id // ""' "$DEPLOY_CONFIG_FILE")
    export TF_VAR_sre_argocd_oidc_client_id
    TF_VAR_sre_prometheus_oidc_client_id=$(jq -r '.sre_prometheus_oidc_client_id // ""' "$DEPLOY_CONFIG_FILE")
    export TF_VAR_sre_prometheus_oidc_client_id
    TF_VAR_sre_thanos_oidc_client_id=$(jq -r '.sre_thanos_oidc_client_id // ""' "$DEPLOY_CONFIG_FILE")
    export TF_VAR_sre_thanos_oidc_client_id

    for svc in grafana argocd prometheus thanos; do
        secret=$(aws secretsmanager get-secret-value \
            --secret-id "sre-ui-alb/${svc}/oidc-client-secret" \
            --region "${TARGET_REGION}" \
            --query SecretString \
            --output text 2>/dev/null || true)
        if [ -z "${secret}" ]; then
            echo "ERROR: Secrets Manager secret 'sre-ui-alb/${svc}/oidc-client-secret' not found in account ${TARGET_ACCOUNT_ID} region ${TARGET_REGION}" >&2
            exit 1
        fi
        export "TF_VAR_sre_${svc}_oidc_client_secret=${secret}"
    done
fi

# MC OU path from SSM (provisioned by account-minter, required for OIDC bucket policy)
TF_VAR_mc_ou_path=$(aws ssm get-parameter \
    --name "/infra/region-ou-path" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text \
    --region "${TARGET_REGION}" 2>/dev/null || true)
if [ -z "${TF_VAR_mc_ou_path}" ]; then
    echo "ERROR: SSM parameter /infra/region-ou-path not found in account ${TARGET_ACCOUNT_ID} region ${TARGET_REGION}" >&2
    exit 1
fi
export TF_VAR_mc_ou_path

if [ -n "${ENVIRONMENT_DOMAIN:-}" ]; then
    export TF_VAR_environment_domain="${ENVIRONMENT_DOMAIN}"
fi
if [ -n "${ENVIRONMENT_HOSTED_ZONE_ID:-}" ]; then
    export TF_VAR_environment_hosted_zone_id="${ENVIRONMENT_HOSTED_ZONE_ID}"
fi

export TF_VAR_regional_id=$(jq -r '.regional_id' "$DEPLOY_CONFIG_FILE")
export TF_VAR_environment=$(jq -r '.environment' "$DEPLOY_CONFIG_FILE")
export TF_VAR_eph_prefix=$(jq -r '.eph_prefix // ""' "$DEPLOY_CONFIG_FILE")
export ENVIRONMENT="${ENVIRONMENT:-staging}"

# Determine terraform action
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

echo "RC ${REGIONAL_ID}: terraform ${TERRAFORM_ACTION} in ${TARGET_ACCOUNT_ID}/${TARGET_REGION}"

cd terraform/config/regional-cluster
terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}" \
    -backend-config="use_lockfile=true"

if [ "${TERRAFORM_ACTION}" == "apply" ] && [ -f imports.sh ]; then
    source imports.sh
fi

terraform "${TERRAFORM_ACTION}" -auto-approve
