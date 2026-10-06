#!/usr/bin/env bash
# Provision or destroy Regional Cluster infrastructure.
# Called from: terraform/config/pipeline-regional-cluster/buildspec-provision-infra.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh
source scripts/pipeline-common/terraform-lib.sh

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

# Fetch PagerDuty token if enabled (config moved to static.tfvars.json)
_RAW_PD=$(jq -r '.enable_pagerduty // false' "$DEPLOY_CONFIG_FILE")
if [ "$_RAW_PD" == "true" ] || [ "$_RAW_PD" == "1" ]; then
    PAGERDUTY_TOKEN=$(secrets_manager_get "pagerduty/service-account" "us-east-1" required)
    export PAGERDUTY_TOKEN
fi

use_mc_account

# Configure Terraform backend (state in target account)
export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="regional-cluster/${REGIONAL_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

# Set dynamic Terraform variables (static vars in static.tfvars.json)
export TF_VAR_region="${TARGET_REGION}"

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

# Static config vars (enable_bastion, hyperfleet_db_*, enable_cloudtrail, etc)
# moved to static.tfvars.json

TF_VAR_enable_sre_public_access=$(parseBool '.enable_sre_public_access' false "$DEPLOY_CONFIG_FILE")
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

# SRE OIDC config (enable_sre_oidc_auth, sre_oidc_issuer_url, sre_*_oidc_client_id)
# moved to static.tfvars.json; only secrets remain dynamic
TF_VAR_enable_sre_oidc_auth=$(parseBool '.enable_sre_oidc_auth' false "$DEPLOY_CONFIG_FILE")
if [ "$TF_VAR_enable_sre_oidc_auth" = "true" ]; then
    for svc in grafana argocd prometheus thanos; do
        secret=$(secrets_manager_get "sre-ui-alb/${svc}/oidc-client-secret" "${TARGET_REGION}" required)
        export "TF_VAR_sre_${svc}_oidc_client_secret=${secret}"
    done
fi

# MC OU path from SSM - backward-compatible: try new nested path first, fall back to legacy flat path
TF_VAR_mc_ou_path=$(ssm_get_param_with_fallback \
    "${TARGET_REGION}" \
    "/infra/${ENVIRONMENT}/${TARGET_REGION}/ou-path" \
    "/infra/region-ou-path")

if [ -z "${TF_VAR_mc_ou_path}" ]; then
    echo "ERROR: MC OU path not found in SSM" >&2
    echo "For stage: parameter is created by rosa-hyperfleet-internal/infra/modules/account-config" >&2
    echo "For ephemeral/integration: manually create at /infra/region-ou-path (legacy) or /infra/${ENVIRONMENT}/${TARGET_REGION}/ou-path (new)" >&2
    exit 1
fi
export TF_VAR_mc_ou_path
export TF_VAR_region_ou_path="${TF_VAR_mc_ou_path}"  # Pass through to terraform

if [ -n "${ENVIRONMENT_DOMAIN:-}" ]; then
    export TF_VAR_environment_domain="${ENVIRONMENT_DOMAIN}"
fi
if [ -n "${ENVIRONMENT_HOSTED_ZONE_ID:-}" ]; then
    export TF_VAR_environment_hosted_zone_id="${ENVIRONMENT_HOSTED_ZONE_ID}"
fi

# Static vars (regional_id, environment, zoa_*, worker_node_ami_id, eph_prefix)
# moved to static.tfvars.json
export ENVIRONMENT="${ENVIRONMENT:-staging}"

# Determine terraform action
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

echo "RC ${REGIONAL_ID}: terraform ${TERRAFORM_ACTION} in ${TARGET_ACCOUNT_ID}/${TARGET_REGION}"

# Deploy dir calculated by lib.sh as dirname of DEPLOY_CONFIG_FILE
DEPLOY_DIR=$(dirname "$DEPLOY_CONFIG_FILE")

# Initialize backend
tf_init_backend \
    terraform/config/regional-cluster \
    "${TF_STATE_BUCKET}" \
    "${TF_STATE_KEY}" \
    "${TF_STATE_REGION}"

# Apply or destroy
tf_apply_with_static_vars \
    terraform/config/regional-cluster \
    "${TERRAFORM_ACTION}" \
    "${DEPLOY_DIR}/static.tfvars.json"
