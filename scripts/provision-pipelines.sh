#!/usr/bin/env bash
# Provision regional and management cluster pipelines from deploy/ directory structure.
#
# Reads region and management cluster configs from deploy/<environment>/<region>/pipeline-provisioner-inputs/
# and runs terraform to create/update the corresponding CodePipeline pipelines.
#
# Required environment variables:
#   ENVIRONMENT          - Target environment (e.g., staging, production)
#   GITHUB_REPOSITORY    - GitHub repository in owner/name format (e.g., 'octocat/hello-world')
#   GITHUB_BRANCH        - GitHub branch to track
#   GITHUB_CONNECTION_ARN - CodeStar connection ARN
#   PLATFORM_IMAGE       - Platform container image URI for CodeBuild projects

set -euo pipefail
trap 'echo "FAILED: line $LINENO, exit code $?" >&2' ERR

echo "Provisioning pipelines for ${ENVIRONMENT:-staging}"

# Compute the platform image reference from the Dockerfile to ensure consistency.
# The Build-Platform-Image stage builds and pushes the image tagged with this hash,
# so we must use the same computation here rather than relying on the PLATFORM_IMAGE
# env var (which is only updated when central-account-bootstrap is re-applied).
DOCKERFILE="terraform/modules/platform-image/Dockerfile"
if [ -f "$DOCKERFILE" ]; then
  _computed_tag=$(sha256sum "$DOCKERFILE" | cut -c1-12)
  _base_repo="${PLATFORM_IMAGE%:*}"
  PLATFORM_IMAGE="${_base_repo}:${_computed_tag}"
  echo "Platform image (computed from Dockerfile): ${PLATFORM_IMAGE}"
fi

# Get central account ID for state bucket
CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"

# Save central credentials for account switching
_CENTRAL_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
_CENTRAL_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
_CENTRAL_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

# Track which target accounts have had state buckets bootstrapped (avoid duplicates)
BOOTSTRAPPED_ACCOUNTS=""

# Bootstrap state bucket in a target account (idempotent)
bootstrap_target_state_bucket() {
    local target_account_id="$1"
    local target_region="$2"

    # Skip if already bootstrapped this account in this run
    if echo "$BOOTSTRAPPED_ACCOUNTS" | grep -q "|${target_account_id}|"; then
        echo "State bucket already bootstrapped for account $target_account_id (skipping)"
        return 0
    fi

    if [ "$target_account_id" = "$CENTRAL_ACCOUNT_ID" ]; then
        # Same account - run bootstrap directly
        ./scripts/bootstrap-state.sh "$target_region"
    else
        # Cross-account - assume role first
        local creds
        if ! creds=$(aws sts assume-role \
            --role-arn "arn:aws:iam::${target_account_id}:role/OrganizationAccountAccessRole" \
            --role-session-name "bootstrap-state-${target_account_id}" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
            --output text 2>&1); then
            echo "ERROR: Failed to assume role in account $target_account_id for state bootstrap"
            echo "Error: $creds"
            return 1
        fi

        # Run bootstrap with target credentials
        AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}') \
        AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}') \
        AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}') \
        ./scripts/bootstrap-state.sh "$target_region"
    fi

    BOOTSTRAPPED_ACCOUNTS="${BOOTSTRAPPED_ACCOUNTS}|${target_account_id}|"
}

# Determine which environment to process (prefer existing, fall back to TARGET_ENVIRONMENT, then staging)
ENVIRONMENT="${ENVIRONMENT:-${TARGET_ENVIRONMENT:-staging}}"

# Validate and sanitize ENVIRONMENT to prevent path traversal and injection
if [[ -z "$ENVIRONMENT" || ! "$ENVIRONMENT" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: ENVIRONMENT is empty or contains invalid characters: '${ENVIRONMENT}'" >&2
    exit 1
fi

# Try to read tf_state_region from the first regional-cluster.json file found
TF_STATE_REGION=""
if [ -d "deploy/${ENVIRONMENT}" ]; then
    # Find first regional-cluster.json file in this environment
    FIRST_REGIONAL_JSON=$(find "deploy/${ENVIRONMENT}" -name "regional-cluster.json" -path "*/pipeline-provisioner-inputs/*" -type f | head -n 1)
    if [ -n "$FIRST_REGIONAL_JSON" ]; then
        TF_STATE_REGION=$(jq -r '.tf_state_region // empty' "$FIRST_REGIONAL_JSON" 2>/dev/null || echo "")
    fi
fi

# If not found in config, try to detect from bucket location
if [ -z "$TF_STATE_REGION" ]; then
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --region us-east-1 --query LocationConstraint --output text 2>/dev/null || echo "")
    if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ] || [ -z "$BUCKET_REGION" ]; then
        TF_STATE_REGION="us-east-1"
    else
        TF_STATE_REGION="$BUCKET_REGION"
    fi
fi


# Helper function: Retry terraform apply with exponential backoff
# Usage: retry_terraform_apply "${TF_ARGS[@]}"
retry_terraform_apply() {
    local max_attempts=3
    local attempt=1
    local wait_time=30

    while [ $attempt -le $max_attempts ]; do
        if terraform apply -auto-approve "$@"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo "Attempt $attempt failed, retrying in ${wait_time}s..."
            sleep $wait_time
            wait_time=$((wait_time * 2))
            attempt=$((attempt + 1))
        else
            echo "ERROR: All $max_attempts attempts failed" >&2
            return 1
        fi
    done
}

# Helper function: Resolve SSM parameter if value starts with "ssm://"
resolve_ssm_param() {
    local value="$1"
    local region="${2:-${AWS_REGION}}"  # Optional region parameter, defaults to AWS_REGION
    if [[ "$value" == ssm://* ]]; then
        local param_name="${value#ssm://}"
            aws ssm get-parameter \
            --name "$param_name" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${region}"
    else
        echo "$value"
    fi
}

# Helper function: Trigger pipeline destruction
# Arguments: pipeline_type (regional/management)
destroy_pipeline() {
    local pipeline_type="$1"
    
    if terraform destroy -auto-approve "${TF_ARGS[@]}"; then
        return 0
    else
        echo "ERROR: Failed to destroy $pipeline_type pipeline resources" >&2
        return 1
    fi
}

# --- BEGIN TEMPORARY CI HACK (remove when e2e uses a dedicated config with per-cluster delete flags) ---
# FORCE_DELETE_ALL_PIPELINES=true force-sets DELETE_FLAG=true for ALL clusters, bypassing
# per-cluster config. This exists solely to let e2e teardown destroy everything without a
# custom config. Passed as a CodePipeline variable from ci/e2e.sh.
FORCE_DELETE_ALL_PIPELINES="${FORCE_DELETE_ALL_PIPELINES:-false}"

PROVISION_FAILURES=0
# --- END TEMPORARY CI HACK ---

if [ ! -d "deploy/${ENVIRONMENT}" ]; then
    echo "ERROR: Environment directory does not exist: deploy/${ENVIRONMENT}" >&2
    exit 1
fi

# Validate at least one region directory exists
shopt -s nullglob
region_dirs=("deploy/${ENVIRONMENT}"/*/)
shopt -u nullglob

if [ ${#region_dirs[@]} -eq 0 ]; then
    echo "ERROR: No region directories found in deploy/${ENVIRONMENT}/" >&2
    exit 1
fi

# =============================================================================
# DNS Environment Zone (optional)
#
# When domain is configured in pipeline-provisioner-inputs/terraform.json, create the environment
# hosted zone (e.g. int0.rosa.devshift.net) in the central account before
# processing regions. The zone ID is passed to regional pipelines for NS delegation.
# =============================================================================

ENVIRONMENT_DOMAIN=""
ENVIRONMENT_HOSTED_ZONE_ID=""

# Read domain from first region's provisioner inputs
for _first_region_dir in deploy/${ENVIRONMENT}/*/; do
    [ -d "$_first_region_dir" ] || continue
    _prov_tf="${_first_region_dir}pipeline-provisioner-inputs/terraform.json"
    if [ -f "$_prov_tf" ]; then
        ENVIRONMENT_DOMAIN=$(jq -r '.domain // empty' "$_prov_tf" 2>/dev/null || echo "")
        CREATE_ENVIRONMENT_ZONE=$(jq -r '.create_environment_zone // "false"' "$_prov_tf" 2>/dev/null || echo "false")
    fi
    break
done

if [ -n "$ENVIRONMENT_DOMAIN" ] && [ "$CREATE_ENVIRONMENT_ZONE" = "true" ]; then
    echo "Provisioning DNS environment zone: $ENVIRONMENT_DOMAIN"

    cd terraform/config/dns-environment-zone

    terraform init \
        -reconfigure \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=dns/environment-zone-${ENVIRONMENT}.tfstate" \
        -backend-config="region=$TF_STATE_REGION" \
        -backend-config="use_lockfile=true"

    if retry_terraform_apply \
        -var="environment_domain=${ENVIRONMENT_DOMAIN}" \
        -var="environment=${ENVIRONMENT}"; then
        ENVIRONMENT_HOSTED_ZONE_ID=$(terraform output -raw zone_id)
    else
        echo "ERROR: Failed to create environment zone: $ENVIRONMENT_DOMAIN" >&2
        exit 1
    fi

    cd ../../..
fi

# Process each region_deployment directory in the target environment
for region_dir in deploy/${ENVIRONMENT}/*/; do
    [ -d "$region_dir" ] || continue

    # Extract region_deployment from directory path
    # e.g., deploy/integration/us-east-1/ -> REGION_DEPLOYMENT=us-east-1
    REGION_DEPLOYMENT=$(basename "$region_dir")

    echo "Processing: $ENVIRONMENT / $REGION_DEPLOYMENT"

    # 1. Check for regional-cluster.json in this region
    if [ -f "${region_dir}pipeline-provisioner-inputs/regional-cluster.json" ]; then
        REGIONAL_CONFIG="${region_dir}pipeline-provisioner-inputs/regional-cluster.json"

        # Extract configuration from JSON
        AWS_REGION=$(jq -r '.region // .target_region // "us-east-1"' "$REGIONAL_CONFIG")
        TARGET_ACCOUNT_ID=$(jq -r '.account_id // ""' "$REGIONAL_CONFIG")
        TARGET_ACCOUNT_ID=$(resolve_ssm_param "$TARGET_ACCOUNT_ID")
        REGIONAL_ID=$(jq -r '.regional_id // ""' "$REGIONAL_CONFIG")

        # Read delete_pipeline from the regional-cluster provisioner input
        DELETE_FLAG=$(jq -r '.delete_pipeline // false' "$REGIONAL_CONFIG")

        # TEMPORARY CI HACK (see top of file)
        # Sets DELETE_FLAG to true if FORCE_DELETE_ALL_PIPELINES is true
        [ "$FORCE_DELETE_ALL_PIPELINES" == "true" ] && DELETE_FLAG="true"

        if [[ -z "$TARGET_ACCOUNT_ID" ]]; then
            echo "ERROR: account_id must be provided for region ${AWS_REGION}" >&2
            exit 1
        fi

        bootstrap_target_state_bucket "$TARGET_ACCOUNT_ID" "$AWS_REGION"

        cd terraform/config/pipeline-regional-cluster

        terraform init \
            -reconfigure \
            -backend-config="bucket=$TF_STATE_BUCKET" \
            -backend-config="key=pipelines/regional-${ENVIRONMENT}-${REGION_DEPLOYMENT}-${REGIONAL_ID}.tfstate" \
            -backend-config="region=$TF_STATE_REGION" \
            -backend-config="use_lockfile=true"

        # Build terraform apply command with variables (array for safe expansion)
        TF_ARGS=(
            -var="github_repository=${GITHUB_REPOSITORY}"
            -var="github_branch=${GITHUB_BRANCH}"
            -var="region=${AWS_REGION}"
        )
        [ -n "$GITHUB_CONNECTION_ARN" ] && TF_ARGS+=( -var="github_connection_arn=${GITHUB_CONNECTION_ARN}" )
        [ -n "$TARGET_ACCOUNT_ID" ] && TF_ARGS+=( -var="target_account_id=${TARGET_ACCOUNT_ID}" )
        [ -n "$AWS_REGION" ] && TF_ARGS+=( -var="target_region=${AWS_REGION}" )
        [ -n "$REGIONAL_ID" ] && TF_ARGS+=( -var="regional_id=${REGIONAL_ID}" )
        [ -n "$ENVIRONMENT" ] && TF_ARGS+=( -var="target_environment=${ENVIRONMENT}" )
        # Repository URL and branch for cluster configuration
        TF_ARGS+=(
            -var="repository_url=https://github.com/${GITHUB_REPOSITORY}.git"
            -var="repository_branch=${GITHUB_BRANCH}"
            -var="codebuild_image=${PLATFORM_IMAGE}"
        )
        # DNS configuration (optional)
        [ -n "$ENVIRONMENT_HOSTED_ZONE_ID" ] && TF_ARGS+=( -var="environment_hosted_zone_id=${ENVIRONMENT_HOSTED_ZONE_ID}" )

        if [ "$DELETE_FLAG" == "true" ]; then
            if destroy_pipeline "regional"; then
                cd ../../..
            else
                cd ../../..
                echo "ERROR: Regional pipeline destroy failed for ${ENVIRONMENT}-${REGION_DEPLOYMENT}, manual intervention required" >&2
                exit 1
            fi
        else
            if retry_terraform_apply "${TF_ARGS[@]}"; then
                cd ../../..
            else
                cd ../../..
                echo "ERROR: Regional pipeline failed for ${ENVIRONMENT}-${REGION_DEPLOYMENT} after retries" >&2
                PROVISION_FAILURES=$((PROVISION_FAILURES + 1))
                continue
            fi
        fi
    fi

    # 2. Check for management-cluster-*.json files in this region
    shopt -s nullglob
    _mc_configs=(${region_dir}pipeline-provisioner-inputs/management-cluster-*.json)
    shopt -u nullglob
    if [ ${#_mc_configs[@]} -gt 0 ]; then
        for mc_config in ${region_dir}pipeline-provisioner-inputs/management-cluster-*.json; do
            [ -e "$mc_config" ] || continue

            # Extract cluster name from filename (e.g., management-cluster-mc01.json -> mc01)
            _mc_basename=$(basename "$mc_config" .json)
            CLUSTER_NAME="${_mc_basename#management-cluster-}"

            AWS_REGION=$(jq -r '.region // .target_region // "us-east-1"' "$mc_config")
            TARGET_ACCOUNT_ID=$(jq -r '.account_id // ""' "$mc_config")
            TARGET_ACCOUNT_ID=$(resolve_ssm_param "$TARGET_ACCOUNT_ID")
            MANAGEMENT_ID=$(jq -r '.management_id // ""' "$mc_config")

            # Read delete_pipeline from the management-cluster provisioner input
            DELETE_FLAG=$(jq -r '.delete_pipeline // false' "$mc_config")

            # TEMPORARY CI HACK (see top of file)
            # Sets DELETE_FLAG to true if FORCE_DELETE_ALL_PIPELINES is true
            [ "$FORCE_DELETE_ALL_PIPELINES" == "true" ] && DELETE_FLAG="true"

            if [[ -z "$TARGET_ACCOUNT_ID" ]]; then
                echo "ERROR: account_id must be provided for management cluster ${CLUSTER_NAME}" >&2
                exit 1
            fi

            bootstrap_target_state_bucket "$TARGET_ACCOUNT_ID" "$AWS_REGION"

            cd terraform/config/pipeline-management-cluster

            terraform init \
                -reconfigure \
                -backend-config="bucket=$TF_STATE_BUCKET" \
                -backend-config="key=pipelines/management-${ENVIRONMENT}-${REGION_DEPLOYMENT}-${CLUSTER_NAME}.tfstate" \
                -backend-config="region=$TF_STATE_REGION" \
                -backend-config="use_lockfile=true"

            # Build terraform apply command with variables (array for safe expansion)
            TF_ARGS=(
                -var="github_repository=${GITHUB_REPOSITORY}"
                -var="github_branch=${GITHUB_BRANCH}"
                -var="region=${AWS_REGION}"
            )
            [ -n "$GITHUB_CONNECTION_ARN" ] && TF_ARGS+=( -var="github_connection_arn=${GITHUB_CONNECTION_ARN}" )
            [ -n "$TARGET_ACCOUNT_ID" ] && TF_ARGS+=( -var="target_account_id=${TARGET_ACCOUNT_ID}" )
            [ -n "$AWS_REGION" ] && TF_ARGS+=( -var="target_region=${AWS_REGION}" )
            [ -n "$MANAGEMENT_ID" ] && TF_ARGS+=( -var="management_id=${MANAGEMENT_ID}" )
            [ -n "$ENVIRONMENT" ] && TF_ARGS+=( -var="target_environment=${ENVIRONMENT}" )
            # Repository URL and branch for cluster configuration
            TF_ARGS+=(
                -var="repository_url=https://github.com/${GITHUB_REPOSITORY}.git"
                -var="repository_branch=${GITHUB_BRANCH}"
                -var="codebuild_image=${PLATFORM_IMAGE}"
            )

            if [ "$DELETE_FLAG" == "true" ]; then
                if destroy_pipeline "management"; then
                    cd ../../..
                else
                    cd ../../..
                    echo "ERROR: Management pipeline destroy failed for $CLUSTER_NAME, manual intervention required" >&2
                    exit 1
                fi
            else
                if retry_terraform_apply "${TF_ARGS[@]}"; then
                    cd ../../..
                else
                    cd ../../..
                    echo "ERROR: Management pipeline failed for $CLUSTER_NAME after retries" >&2
                    PROVISION_FAILURES=$((PROVISION_FAILURES + 1))
                    continue
                fi
            fi
        done
    fi

done

if [ "$PROVISION_FAILURES" -gt 0 ]; then
    echo "ERROR: Pipeline provisioning completed with $PROVISION_FAILURES failure(s)" >&2
    exit 1
fi
