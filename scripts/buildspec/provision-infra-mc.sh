#!/usr/bin/env bash
# Provision or destroy Management Cluster infrastructure.
# Called from: terraform/config/pipeline-management-cluster/buildspec-provision-infra.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh
source scripts/pipeline-common/terraform-lib.sh

preflight_check
config_load management

DEPLOY_DIR=$(dirname "$DEPLOY_CONFIG_FILE")
STATIC_TFVARS="${DEPLOY_DIR}/static.tfvars.json"
_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"
_ZOA_LAMBDA_IMAGE_TAG=$(jq -r '.zoa_lambda_image_tag // empty' "$STATIC_TFVARS")
_RC_CODEBUILD_BUILD_ID="${RC_CODEBUILD_BUILD_ID:-}"

require_nonempty_vars "MC core runtime" \
    TARGET_ACCOUNT_ID TARGET_REGION MANAGEMENT_ID REGIONAL_AWS_ACCOUNT_ID \
    REPOSITORY_URL PLATFORM_IMAGE
validate_aws_account_id "TARGET_ACCOUNT_ID" "${TARGET_ACCOUNT_ID}"
validate_aws_account_id "REGIONAL_AWS_ACCOUNT_ID" "${REGIONAL_AWS_ACCOUNT_ID}"
tf_require_static_vars "${STATIC_TFVARS}" "MC core" \
    management_id environment app_code service_phase cost_center \
    regional_aws_account_id
tf_require_static_keys "${STATIC_TFVARS}" "MC" \
    zoa_lambda_image_tag zoa_runner_image_tag zoa_runner_source_image \
    worker_node_ami_id worker_node_root_volume_size

_STATIC_MANAGEMENT_ID=$(jq -r '.management_id // empty' "${STATIC_TFVARS}")
_STATIC_ENVIRONMENT=$(jq -r '.environment // empty' "${STATIC_TFVARS}")
_STATIC_REGIONAL_ACCOUNT_ID=$(jq -r '.regional_aws_account_id // empty' "${STATIC_TFVARS}")
if [[ "${_STATIC_MANAGEMENT_ID}" != "${MANAGEMENT_ID}" ]]; then
    echo "ERROR: MC management_id mismatch: static=${_STATIC_MANAGEMENT_ID}, runtime=${MANAGEMENT_ID}" >&2
    exit 1
fi
if [[ "${_STATIC_ENVIRONMENT}" != "${ENVIRONMENT}" ]]; then
    echo "ERROR: MC environment mismatch: static=${_STATIC_ENVIRONMENT}, runtime=${ENVIRONMENT}" >&2
    exit 1
fi
if [[ "${_STATIC_REGIONAL_ACCOUNT_ID}" != "${REGIONAL_AWS_ACCOUNT_ID}" ]]; then
    echo "ERROR: MC regional account mismatch: static=${_STATIC_REGIONAL_ACCOUNT_ID}, runtime=${REGIONAL_AWS_ACCOUNT_ID}" >&2
    exit 1
fi
if [[ -n "${_ZOA_LAMBDA_IMAGE_TAG}" ]]; then
    tf_require_static_vars "${STATIC_TFVARS}" "MC ZOA" \
        zoa_lambda_image_tag zoa_runner_image_tag zoa_runner_source_image
fi

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

    _RC_CONFIG_FILE=$(config_path_for_mode regional)
    _RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "$_RC_CONFIG_FILE" 2>/dev/null || echo "regional")
    _RC_CODEBUILD_PROJECT="${RC_CODEBUILD_PROJECT:-${_RC_REGIONAL_ID}}"

    _read_rc_builds() {
        local build_ids_json
        if [[ -n "${_RC_CODEBUILD_BUILD_ID}" ]]; then
            AWS_ACCESS_KEY_ID="${_CENTRAL_AWS_ACCESS_KEY_ID}" \
            AWS_SECRET_ACCESS_KEY="${_CENTRAL_AWS_SECRET_ACCESS_KEY}" \
            AWS_SESSION_TOKEN="${_CENTRAL_AWS_SESSION_TOKEN}" \
            AWS_DEFAULT_REGION="${TARGET_REGION}" \
            AWS_REGION="${TARGET_REGION}" \
                aws codebuild batch-get-builds \
                    --ids "${_RC_CODEBUILD_BUILD_ID}" --output json --no-cli-pager
            return
        fi

        if ! build_ids_json=$(
            AWS_ACCESS_KEY_ID="${_CENTRAL_AWS_ACCESS_KEY_ID}" \
            AWS_SECRET_ACCESS_KEY="${_CENTRAL_AWS_SECRET_ACCESS_KEY}" \
            AWS_SESSION_TOKEN="${_CENTRAL_AWS_SESSION_TOKEN}" \
            AWS_DEFAULT_REGION="${TARGET_REGION}" \
            AWS_REGION="${TARGET_REGION}" \
                aws codebuild list-builds-for-project \
                    --project-name "${_RC_CODEBUILD_PROJECT}" \
                    --sort-order DESCENDING --output json --no-cli-pager
        ); then
            echo "ERROR: Unable to inspect RC CodeBuild project ${_RC_CODEBUILD_PROJECT}" >&2
            return 1
        fi

        local build_ids=()
        mapfile -t build_ids < <(jq -r '.ids[:20][]?' <<<"${build_ids_json}")
        if [[ ${#build_ids[@]} -eq 0 ]]; then
            return 2
        fi

        AWS_ACCESS_KEY_ID="${_CENTRAL_AWS_ACCESS_KEY_ID}" \
        AWS_SECRET_ACCESS_KEY="${_CENTRAL_AWS_SECRET_ACCESS_KEY}" \
        AWS_SESSION_TOKEN="${_CENTRAL_AWS_SESSION_TOKEN}" \
        AWS_DEFAULT_REGION="${TARGET_REGION}" \
        AWS_REGION="${TARGET_REGION}" \
            aws codebuild batch-get-builds \
                --ids "${build_ids[@]}" --output json --no-cli-pager
    }

    check_rc_build_status() {
        local builds_json build_json status applied applied_sha desired_sha
        local read_status=0
        builds_json=$(_read_rc_builds) || read_status=$?
        if [[ ${read_status} -eq 1 ]]; then
            return 1
        fi
        if [[ ${read_status} -eq 2 ]]; then
            return 2
        fi

        desired_sha="${CODEBUILD_RESOLVED_SOURCE_VERSION:-}"
        if [[ -n "${_RC_CODEBUILD_BUILD_ID}" ]]; then
            build_json=$(jq -c '.builds[0] // empty' <<<"${builds_json}")
        else
            # Ignore successful queue-skipped builds. They may be newer than
            # the valid applied build but have APPLIED=false.
            build_json=$(jq -c --arg sha "${desired_sha}" '
                [
                    .builds[]?
                    | select(.sourceVersion == $sha or .resolvedSourceVersion == $sha)
                    | select(
                        .buildStatus != "SUCCEEDED"
                        or (
                            (
                                [.exportedEnvironmentVariables[]?
                                 | select(.name == "APPLIED")
                                 | .value] | last
                            ) == "true"
                            and
                            (
                                [.exportedEnvironmentVariables[]?
                                 | select(.name == "APPLIED_SHA")
                                 | .value] | last
                            ) == $sha
                        )
                    )
                ]
                | sort_by(.startTime // "") | last // empty
            ' <<<"${builds_json}")
        fi
        if [[ -z "${build_json}" ]]; then
            return 2
        fi

        status=$(jq -r '.buildStatus // "UNKNOWN"' <<<"${build_json}")
        case "${status}" in
            QUEUED|IN_PROGRESS)
                echo "MC dependency: RC build ${_RC_CODEBUILD_BUILD_ID:-${_RC_CODEBUILD_PROJECT}} is ${status}; waiting for RC completion"
                return 2
                ;;
            SUCCEEDED)
                applied=$(jq -r '(.exportedEnvironmentVariables // [])[] | select(.name == "APPLIED") | .value' <<<"${build_json}" | tail -n 1)
                applied_sha=$(jq -r '(.exportedEnvironmentVariables // [])[] | select(.name == "APPLIED_SHA") | .value' <<<"${build_json}" | tail -n 1)
                if [[ "${applied}" != "true" || -z "${desired_sha}" || "${applied_sha}" != "${desired_sha}" ]]; then
                    echo "ERROR: RC build ${_RC_CODEBUILD_BUILD_ID:-${_RC_CODEBUILD_PROJECT}} succeeded without APPLIED=true and the expected APPLIED_SHA; MC cannot continue." >&2
                    return 1
                fi
                return 0
                ;;
            FAILED|FAULT|STOPPED|TIMED_OUT)
                echo "ERROR: RC build ${_RC_CODEBUILD_BUILD_ID:-${_RC_CODEBUILD_PROJECT}} failed with status ${status}; MC cannot continue." >&2
                return 1
                ;;
            *)
                echo "ERROR: RC build ${_RC_CODEBUILD_BUILD_ID:-${_RC_CODEBUILD_PROJECT}} has unknown status ${status}; MC cannot continue." >&2
                return 1
                ;;
        esac
    }

    wait_for_rc_outputs() {
        local tf_dir="$1" max_attempts="$2" retry_delay="$3"
        shift 3
        local output_names=("$@")
        local attempt rc_status rc_complete

        echo "Waiting for ${#output_names[@]} required RC Terraform outputs..."
        echo "  RC CodeBuild project: ${_RC_CODEBUILD_PROJECT}"
        echo "  RC CodeBuild build: ${_RC_CODEBUILD_BUILD_ID:-discover by SHA}"
        echo "  Max wait: $((max_attempts * retry_delay / 60)) minutes (${max_attempts} attempts * ${retry_delay}s)"

        for ((attempt = 1; attempt <= max_attempts; attempt++)); do
            rc_complete=false
            if check_rc_build_status; then
                rc_complete=true
            else
                rc_status=$?
                [[ ${rc_status} -eq 1 ]] && return 1
            fi

            if tf_wait_for_outputs "${tf_dir}" 1 0 "${output_names[@]}"; then
                echo "✓ Required RC outputs are ready; MC will continue while RC finishes"
                return 0
            fi

            if [[ "${rc_complete}" == "true" ]]; then
                echo "ERROR: RC build succeeded but required RC outputs are missing; MC cannot continue" >&2
                return 1
            fi

            if [[ ${attempt} -lt ${max_attempts} ]]; then
                echo "  RC dependency/output not ready (attempt ${attempt}/${max_attempts}); retrying in ${retry_delay}s..."
                sleep "${retry_delay}"
            fi
        done

        echo "ERROR: Required RC outputs were not ready after $((max_attempts * retry_delay / 60))+ minutes" >&2
        return 1
    }

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

    # RC and MC pipelines run in parallel — wait for all outputs consumed by MC
    # Terraform to appear. ZOA Lambda deployment is enabled when the configured
    # image tag is non-empty, so its RC outputs are required in that case.
    # rhobs_api_url is NOT consumed by MC terraform (only re-emitted at outputs.tf);
    # bootstrap-argocd-mc.sh already polls it before ArgoCD bootstrap.

    # Set RC credentials for tf_wait_for_outputs (library reads terraform state)
    export AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}')

    _RC_REQUIRED_OUTPUTS=(
        oidc_cloudfront_domain
        oidc_bucket_name
        oidc_bucket_arn
        oidc_bucket_region
    )
    if [[ -n "$_ZOA_LAMBDA_IMAGE_TAG" ]]; then
        _RC_REQUIRED_OUTPUTS+=(
            zoa_bucket_arn
            zoa_kms_key_arn
            zoa_table_name
            zoa_table_arn
            zoa_audit_table_name
            zoa_audit_table_arn
            zoa_uploader_role_arn
            zoa_data_access_role_arn
            zoa_lambda_ecr_url
        )
    fi

    # Wait up to 45 minutes (90 attempts * 30s) for all required RC outputs.
    # MC starts consuming them as soon as they are available; RC may continue
    # with its remaining bootstrap/readiness steps in parallel. If RC fails
    # before the outputs are ready, the MC build fails explicitly.
    wait_for_rc_outputs \
        "$_RC_TF_DIR" \
        90 \
        30 \
        "${_RC_REQUIRED_OUTPUTS[@]}" || {
        echo "ERROR: Failed to read required RC outputs for MC provisioning" >&2
        exit 1
    }
    # TF_VAR_* variables auto-exported by tf_wait_for_outputs

    if [[ -n "$_ZOA_LAMBDA_IMAGE_TAG" ]]; then
        # Read ZOA outputs with validation after the wait above. These values
        # are required by the MC Lambda module and must not be silently empty.
        TF_VAR_zoa_outputs_bucket_arn=$(tf_read_output "$_RC_TF_DIR" zoa_bucket_arn '^arn:')
        export TF_VAR_zoa_outputs_bucket_arn

        TF_VAR_zoa_kms_key_arn=$(tf_read_output "$_RC_TF_DIR" zoa_kms_key_arn '^arn:')
        export TF_VAR_zoa_kms_key_arn

        # ZOA Lambda data-layer outputs (DynamoDB tables + uploader role in RC account)
        TF_VAR_zoa_table_name=$(tf_read_output "$_RC_TF_DIR" zoa_table_name)
        export TF_VAR_zoa_table_name

        TF_VAR_zoa_table_arn=$(tf_read_output "$_RC_TF_DIR" zoa_table_arn '^arn:')
        export TF_VAR_zoa_table_arn

        TF_VAR_zoa_audit_table_name=$(tf_read_output "$_RC_TF_DIR" zoa_audit_table_name)
        export TF_VAR_zoa_audit_table_name

        TF_VAR_zoa_audit_table_arn=$(tf_read_output "$_RC_TF_DIR" zoa_audit_table_arn '^arn:')
        export TF_VAR_zoa_audit_table_arn

        TF_VAR_zoa_uploader_role_arn=$(tf_read_output "$_RC_TF_DIR" zoa_uploader_role_arn '^arn:')
        export TF_VAR_zoa_uploader_role_arn

        TF_VAR_zoa_data_access_role_arn=$(tf_read_output "$_RC_TF_DIR" zoa_data_access_role_arn '^arn:')
        export TF_VAR_zoa_data_access_role_arn

        # Lambda image lives in RC's ECR (cross-account pull via OU policy).
        TF_VAR_zoa_lambda_ecr_url=$(tf_read_output "$_RC_TF_DIR" zoa_lambda_ecr_url)
        export TF_VAR_zoa_lambda_ecr_url
    fi

    require_nonempty_vars "MC RC dependency" \
        TF_VAR_oidc_cloudfront_domain TF_VAR_oidc_bucket_name \
        TF_VAR_oidc_bucket_arn TF_VAR_oidc_bucket_region \
        DNS_ZONE_OPERATOR_ROLE_ARN OIDC_WRITER_ROLE_ARN OIDC_KEY_READER_ROLE_ARN
    validate_arn_account "DNS_ZONE_OPERATOR_ROLE_ARN" \
        "${DNS_ZONE_OPERATOR_ROLE_ARN}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    validate_arn_account "OIDC_WRITER_ROLE_ARN" \
        "${OIDC_WRITER_ROLE_ARN}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    validate_arn_account "OIDC_KEY_READER_ROLE_ARN" \
        "${OIDC_KEY_READER_ROLE_ARN}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    if [[ -n "${_ZOA_LAMBDA_IMAGE_TAG}" ]]; then
        require_nonempty_vars "MC ZOA RC dependency" \
            TF_VAR_zoa_outputs_bucket_arn TF_VAR_zoa_kms_key_arn \
            TF_VAR_zoa_table_name TF_VAR_zoa_table_arn \
            TF_VAR_zoa_audit_table_name TF_VAR_zoa_audit_table_arn \
            TF_VAR_zoa_uploader_role_arn TF_VAR_zoa_data_access_role_arn \
            TF_VAR_zoa_lambda_ecr_url
        validate_arn_account "TF_VAR_zoa_kms_key_arn" \
            "${TF_VAR_zoa_kms_key_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
        validate_arn_account "TF_VAR_zoa_table_arn" \
            "${TF_VAR_zoa_table_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
        validate_arn_account "TF_VAR_zoa_audit_table_arn" \
            "${TF_VAR_zoa_audit_table_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
        validate_arn_account "TF_VAR_zoa_uploader_role_arn" \
            "${TF_VAR_zoa_uploader_role_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
        validate_arn_account "TF_VAR_zoa_data_access_role_arn" \
            "${TF_VAR_zoa_data_access_role_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    fi
fi

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

export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

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

validate_aws_account_id "RESOLVED_REGIONAL_ACCOUNT_ID" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
if [[ "${_STATIC_REGIONAL_ACCOUNT_ID}" != "${RESOLVED_REGIONAL_ACCOUNT_ID}" ]]; then
    echo "ERROR: MC RC dependency account mismatch: static=${_STATIC_REGIONAL_ACCOUNT_ID}, resolved=${RESOLVED_REGIONAL_ACCOUNT_ID}" >&2
    exit 1
fi
require_nonempty_vars "MC Terraform runtime" \
    TF_VAR_region TF_VAR_environment TF_VAR_regional_aws_account_id \
    TF_VAR_repository_url TF_VAR_repository_branch TF_VAR_container_image \
    TF_STATE_BUCKET TF_STATE_KEY

print_provision_param_summary "MC" \
    "management_id" "static" "${_STATIC_MANAGEMENT_ID}" \
    "MANAGEMENT_ID" "runtime" "${MANAGEMENT_ID}" \
    "TARGET_ACCOUNT_ID" "runtime" "${TARGET_ACCOUNT_ID}" \
    "REGIONAL_AWS_ACCOUNT_ID" "runtime" "${RESOLVED_REGIONAL_ACCOUNT_ID}" \
    "TARGET_REGION" "runtime" "${TARGET_REGION}" \
    "REPOSITORY_URL" "runtime" "${REPOSITORY_URL}" \
    "REPOSITORY_BRANCH" "runtime" "${_REPO_BRANCH}" \
    "PLATFORM_IMAGE" "runtime" "${PLATFORM_IMAGE}" \
    "RC_STATE_BUCKET" "RC state" "${_RC_STATE_BUCKET:-<destroy-placeholder>}" \
    "RC_STATE_KEY" "RC state" "${_RC_STATE_KEY:-<destroy-placeholder>}" \
    "oidc_cloudfront_domain" "RC state" "${TF_VAR_oidc_cloudfront_domain:-}" \
    "oidc_bucket_arn" "RC state" "${TF_VAR_oidc_bucket_arn:-}" \
    "zoa_lambda_ecr_url" "RC state" "${TF_VAR_zoa_lambda_ecr_url:-}" \
    "zoa_lambda_image_tag" "static" "${_ZOA_LAMBDA_IMAGE_TAG}" \
    "TF_STATE_BUCKET" "runtime" "${TF_STATE_BUCKET}" \
    "TF_STATE_KEY" "runtime" "${TF_STATE_KEY}"

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

if [[ "${TERRAFORM_ACTION}" == "apply" ]]; then
    _MC_REQUIRED_OUTPUTS=(
        "cluster_name"
        "cluster_endpoint|^https://"
        "vpc_id|^vpc-"
        "oidc_bucket_name"
        "oidc_cloudfront_domain"
    )
    if [[ -n "${_ZOA_LAMBDA_IMAGE_TAG}" ]]; then
        _MC_REQUIRED_OUTPUTS+=("zoa_api_function_url|^https://")
    fi
    tf_validate_outputs terraform/config/management-cluster "MC" "${_MC_REQUIRED_OUTPUTS[@]}" || exit 1
fi
