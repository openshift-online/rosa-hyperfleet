#!/usr/bin/env bash
# SDK-based provisioner: creates/updates/deletes CodeBuild projects via AWS SDK
# (replaces terraform-of-pipelines for RC/MC projects)
#
# Required environment variables:
#   ENVIRONMENT          - Target environment (e.g., staging, production)
#   GITHUB_REPOSITORY    - GitHub repository in owner/name format
#   GITHUB_BRANCH        - GitHub branch to track
#   GITHUB_CONNECTION_ARN - resolved CodeStar connection ARN from bootstrap
#   PLATFORM_IMAGE       - Platform container image URI
#   RC_CODEBUILD_ROLE_ARN - ARN of the centrally-managed RC CodeBuild role
#   MC_CODEBUILD_ROLE_ARN - ARN of the shared MC CodeBuild role

set -euo pipefail
trap 'echo "FAILED: line $LINENO, exit code $?" >&2' ERR

echo "Provisioning cluster CodeBuild projects for ${ENVIRONMENT:-staging}"

# ──────────────────────────────────────────────────────────────────────────────
# Platform Image Computation (ADR: fail-closed image check)
# ──────────────────────────────────────────────────────────────────────────────

DOCKERFILE="terraform/modules/platform-image/Dockerfile"
if [ -f "$DOCKERFILE" ]; then
  _computed_tag=$(sha256sum "$DOCKERFILE" | cut -c1-12)
  _base_repo="${PLATFORM_IMAGE%:*}"
  PLATFORM_IMAGE="${_base_repo}:${_computed_tag}"
  echo "Platform image (computed from Dockerfile): ${PLATFORM_IMAGE}"
fi

# Fail-closed: verify image exists in ECR before create/update
verify_platform_image_exists() {
    local image_uri="$1"
    local repo="${image_uri%:*}"
    local tag="${image_uri##*:}"
    local repository_name

    # Public ECR uses different API
    if [[ "$repo" =~ ^public\.ecr\.aws ]]; then
        # Remove the public ECR registry alias but preserve nested repository paths.
        repository_name="${repo#public.ecr.aws/}"
        repository_name="${repository_name#*/}"
        if ! aws ecr-public describe-images --repository-name "$repository_name" --image-ids imageTag="$tag" --region us-east-1 --no-cli-pager >/dev/null 2>&1; then
            return 1
        fi
    else
        # Private ECR - extract region from repo URI
        local region="${repo#*.ecr.}"
        region="${region%%.*}"
        repository_name="${repo#*/}"
        if ! aws ecr describe-images --repository-name "$repository_name" --image-ids imageTag="$tag" --region "$region" --no-cli-pager >/dev/null 2>&1; then
            return 1
        fi
    fi

    return 0
}

# Ensure platform image exists; build if missing (Day-0/1)
ensure_platform_image() {
    local image_uri="$1"

    echo "Ensuring platform image exists: $image_uri"

    if verify_platform_image_exists "$image_uri"; then
        echo "✓ Platform image exists: $image_uri"
        return 0
    fi

    echo "Platform image not found in ECR — building now..."

    # Determine build project name
    local project_name="${NAME_PREFIX:+${NAME_PREFIX}-}build-platform-image"

    # Get current git SHA (or use HEAD if not available)
    local git_sha
    if git_sha=$(git rev-parse HEAD 2>/dev/null); then
        echo "Building at git SHA: $git_sha"
    else
        git_sha="HEAD"
        echo "WARNING: git not available, using sourceVersion=HEAD"
    fi

    # Start the build
    echo "Starting build: $project_name"
    local build_id
    if ! build_id=$(aws codebuild start-build \
        --project-name "$project_name" \
        --source-version "$git_sha" \
        --query 'build.id' \
        --output text \
        --no-cli-pager 2>&1); then
        echo "ERROR: Failed to start build for $project_name" >&2
        echo "$build_id" >&2
        exit 1
    fi

    echo "Build started: $build_id"

    # Wait for build to complete (poll every 15s, timeout 30 min)
    local max_wait=1800
    local waited=0
    local poll_interval=15

    while [ $waited -lt $max_wait ]; do
        local status
        if ! status=$(aws codebuild batch-get-builds \
            --ids "$build_id" \
            --query 'builds[0].buildStatus' \
            --output text \
            --no-cli-pager 2>&1); then
            echo "WARNING: batch-get-builds failed, retrying..." >&2
            sleep $poll_interval
            waited=$((waited + poll_interval))
            continue
        fi

        case "$status" in
            SUCCEEDED)
                echo "✓ Build succeeded: $build_id"
                break
                ;;
            FAILED|TIMED_OUT|FAULT|STOPPED)
                echo "ERROR: Build failed with status: $status" >&2
                echo "Check CloudWatch logs for build: $build_id" >&2
                exit 1
                ;;
            IN_PROGRESS|QUEUED)
                echo "  [$waited/${max_wait}s] Build status: $status"
                sleep $poll_interval
                waited=$((waited + poll_interval))
                ;;
            *)
                echo "WARNING: Unknown build status: $status" >&2
                sleep $poll_interval
                waited=$((waited + poll_interval))
                ;;
        esac
    done

    if [ $waited -ge $max_wait ]; then
        echo "ERROR: Build did not complete within ${max_wait}s" >&2
        exit 1
    fi

    # Re-verify image now exists
    echo "Re-verifying platform image after build..."
    if ! verify_platform_image_exists "$image_uri"; then
        echo "ERROR: Platform image still missing after successful build!" >&2
        exit 1
    fi

    echo "✓ Platform image built and verified: $image_uri"
}

# ──────────────────────────────────────────────────────────────────────────────
# Helper Functions (preserved from original)
# ──────────────────────────────────────────────────────────────────────────────

# Get central account ID for state bucket
CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"

# Save central credentials for account switching
_CENTRAL_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
_CENTRAL_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
_CENTRAL_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

# Track which target accounts have had state buckets bootstrapped
BOOTSTRAPPED_ACCOUNTS=""

# Bootstrap state bucket in a target account (idempotent)
bootstrap_target_state_bucket() {
    local target_account_id="$1"
    local target_region="$2"

    if echo "$BOOTSTRAPPED_ACCOUNTS" | grep -q "|${target_account_id}|"; then
        echo "State bucket already bootstrapped for account $target_account_id (skipping)"
        return 0
    fi

    if [ "$target_account_id" = "$CENTRAL_ACCOUNT_ID" ]; then
        ./scripts/bootstrap-state.sh "$target_region"
    else
        local admin_role="${CHILD_ADMIN_ROLE_NAME:-OrganizationAccountAccessRole}"
        local creds
        if ! creds=$(aws sts assume-role \
            --role-arn "arn:aws:iam::${target_account_id}:role/${admin_role}" \
            --role-session-name "bootstrap-state-${target_account_id}" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
            --output text 2>&1); then
            echo "ERROR: Failed to assume ${admin_role} role in account $target_account_id"
            echo "Error: $creds"
            return 1
        fi

        AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}') \
        AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}') \
        AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}') \
        ./scripts/bootstrap-state.sh "$target_region"
    fi

    BOOTSTRAPPED_ACCOUNTS="${BOOTSTRAPPED_ACCOUNTS}|${target_account_id}|"
}

# Resolve SSM parameter if value starts with "ssm://"
resolve_ssm_param() {
    local value="$1"
    local region="${2:-${AWS_REGION}}"
    if [[ "$value" == ssm://* ]]; then
        local param_name="${value#ssm://}"
        aws ssm get-parameter \
            --name "$param_name" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${region}" \
            --no-cli-pager
    else
        echo "$value"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SDK Functions (NEW)
# ──────────────────────────────────────────────────────────────────────────────

# Generate CodeBuild project spec JSON (deterministic jq output for hashing)
# Args: cluster_type (regional|management) [followed by config vars via env]
generate_project_spec() {
    local cluster_type="$1"
    local project_name="$2"
    local service_role_arn="$3"
    local buildspec_path="$4"
    local timeout_minutes="$5"

    # Build environment variables array
    local env_vars='[]'
    env_vars=$(jq -n \
        --arg github_repo "$GITHUB_REPOSITORY" \
        --arg github_branch "$GITHUB_BRANCH" \
        --arg environment "$ENVIRONMENT" \
        --arg github_conn_arn "$GITHUB_CONNECTION_ARN" \
        --arg platform_image "$PLATFORM_IMAGE" \
        --arg target_account_id "${TARGET_ACCOUNT_ID:-}" \
        --arg target_region "${AWS_REGION:-us-east-1}" \
        --arg child_admin_role "${CHILD_ADMIN_ROLE_NAME:-OrganizationAccountAccessRole}" \
        --arg repo_url "https://github.com/$GITHUB_REPOSITORY.git" \
        --arg repo_branch "$GITHUB_BRANCH" \
        '[
            {name: "GITHUB_REPOSITORY", value: $github_repo, type: "PLAINTEXT"},
            {name: "GITHUB_BRANCH", value: $github_branch, type: "PLAINTEXT"},
            {name: "ENVIRONMENT", value: $environment, type: "PLAINTEXT"},
            {name: "GITHUB_CONNECTION_ARN", value: $github_conn_arn, type: "PLAINTEXT"},
            {name: "PLATFORM_IMAGE", value: $platform_image, type: "PLAINTEXT"},
            {name: "TARGET_ACCOUNT_ID", value: $target_account_id, type: "PLAINTEXT"},
            {name: "TARGET_REGION", value: $target_region, type: "PLAINTEXT"},
            {name: "CHILD_ADMIN_ROLE_NAME", value: $child_admin_role, type: "PLAINTEXT"},
            {name: "REPOSITORY_URL", value: $repo_url, type: "PLAINTEXT"},
            {name: "REPOSITORY_BRANCH", value: $repo_branch, type: "PLAINTEXT"}
        ]')

    # Add cluster-type-specific env vars
    if [ "$cluster_type" = "regional" ]; then
        env_vars=$(echo "$env_vars" | jq \
            --arg regional_id "${REGIONAL_ID:-}" \
            --arg zone_id "${ENVIRONMENT_HOSTED_ZONE_ID:-}" \
            '. + [
                {name: "REGIONAL_ID", value: $regional_id, type: "PLAINTEXT"},
                {name: "ENVIRONMENT_HOSTED_ZONE_ID", value: $zone_id, type: "PLAINTEXT"}
            ]')
    elif [ "$cluster_type" = "management" ]; then
        env_vars=$(echo "$env_vars" | jq \
            --arg management_id "${MANAGEMENT_ID:-}" \
            '. + [{name: "MANAGEMENT_ID", value: $management_id, type: "PLAINTEXT"}]')
    fi

    # Generate the full project spec (keys sorted for deterministic hash)
    jq -n -S \
        --arg name "$project_name" \
        --arg role_arn "$service_role_arn" \
        --arg image "$PLATFORM_IMAGE" \
        --arg buildspec "$buildspec_path" \
        --argjson timeout "$timeout_minutes" \
        --arg github_repo "$GITHUB_REPOSITORY" \
        --arg github_branch "$GITHUB_BRANCH" \
        --arg github_conn_arn "$GITHUB_CONNECTION_ARN" \
        --argjson env_vars "$env_vars" \
        '{
            name: $name,
            serviceRole: $role_arn,
            artifacts: {type: "NO_ARTIFACTS"},
            environment: {
                type: "LINUX_CONTAINER",
                image: $image,
                computeType: "BUILD_GENERAL1_SMALL",
                imagePullCredentialsType: "CODEBUILD",
                privilegedMode: false,
                environmentVariables: $env_vars
            },
            source: {
                type: "GITHUB",
                location: ("https://github.com/" + $github_repo + ".git"),
                gitCloneDepth: 0,
                buildspec: $buildspec,
                gitSubmodulesConfig: {fetchSubmodules: false},
                auth: {
                    type: "CODECONNECTIONS",
                    resource: $github_conn_arn
                }
            },
            timeoutInMinutes: $timeout,
            concurrentBuildLimit: 1
        }'
}

# Compute hash1 (SHA256 of spec with .tags stripped)
compute_spec_hash() {
    local spec="$1"
    echo "$spec" | jq -S 'del(.tags)' | sha256sum | awk '{print $1}'
}

# Retry wrapper for create/update-webhook (ADR: GitHub App rate limit)
retry_webhook_operation() {
    local operation="$1"  # create-webhook or update-webhook
    shift
    local args=("$@")

    local max_attempts=3
    local attempt=1
    local wait_time=5

    while [ $attempt -le $max_attempts ]; do
        if aws codebuild "$operation" "${args[@]}" --no-cli-pager 2>&1; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo "Webhook $operation failed (attempt $attempt/$max_attempts), retrying in ${wait_time}s..."
            sleep $wait_time
            wait_time=$((wait_time * 2))
            attempt=$((attempt + 1))
        else
            echo "ERROR: Webhook $operation failed after $max_attempts attempts" >&2
            echo "Check that the GitHub App has the 'webhooks' permission scope granted." >&2
            return 1
        fi
    done
}

# Generate webhook filter groups (ADR glob→regex)
generate_webhook_filters() {
    local cluster_type="$1"
    local branch="$2"
    local env="$3"
    local region_deployment="$4"
    local cluster_id="${5:-}"  # REGIONAL_ID or MANAGEMENT_ID

    local head_ref_pattern="^refs/heads/${branch}\$"

    if [ "$cluster_type" = "regional" ]; then
        # RC: 6 filter groups (ADR paths exactly)
        jq -n \
            --arg branch_pattern "$head_ref_pattern" \
            --arg env "$env" \
            --arg region "$region_deployment" \
            '[
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: ("^deploy/" + $env + "/" + $region + "/codebuild-regional-cluster-inputs/terraform\\\\.json$")}
                ],
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: "^terraform/config/codebuild-regional-cluster/.*"}
                ],
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: "^terraform/config/regional-cluster/.*"}
                ],
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: "^terraform/modules/zoa/.*"}
                ],
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: "^terraform/modules/zoa-lambda/.*"}
                ],
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: "^scripts/buildspec/build-zoa-lambda\\\\.sh$"}
                ]
            ]'
    elif [ "$cluster_type" = "management" ]; then
        # MC: 3 filter groups
        jq -n \
            --arg branch_pattern "$head_ref_pattern" \
            --arg env "$env" \
            --arg region "$region_deployment" \
            --arg mc_id "$cluster_id" \
            '[
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: ("^deploy/" + $env + "/" + $region + "/codebuild-management-cluster-" + $mc_id + "-inputs/terraform\\\\.json$")}
                ],
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: "^terraform/config/codebuild-management-cluster/.*"}
                ],
                [
                    {type: "EVENT", pattern: "PUSH"},
                    {type: "HEAD_REF", pattern: $branch_pattern},
                    {type: "FILE_PATH", pattern: "^terraform/config/kube-applier-dynamodb-provisioning/.*"}
                ]
            ]'
    fi
}

# Upsert (create or update) a CodeBuild project with two-hash idempotency
upsert_project() {
    local cluster_type="$1"      # regional or management
    local project_name="$2"
    local service_role_arn="$3"
    local buildspec_path="$4"
    local timeout_minutes="$5"

    echo "═══ Upserting CodeBuild project: $project_name ($cluster_type) ═══"

    # Generate the desired spec
    local spec
    spec=$(generate_project_spec "$cluster_type" "$project_name" "$service_role_arn" "$buildspec_path" "$timeout_minutes")
    local desired_hash
    desired_hash=$(compute_spec_hash "$spec")

    echo "Desired spec hash (hash1): $desired_hash"

    # Check if project exists
    local existing_project
    if existing_project=$(aws codebuild batch-get-projects --names "$project_name" --query 'projects[0]' --output json --no-cli-pager 2>/dev/null); then
        if [ "$(echo "$existing_project" | jq -r '.name // empty')" = "$project_name" ]; then
            echo "Project exists, checking for drift..."

            # Read current DefinitionHash tag
            local current_hash
            current_hash=$(echo "$existing_project" | jq -r '.tags[] | select(.key == "DefinitionHash") | .value // empty')

            if [ "$current_hash" = "$desired_hash" ]; then
                echo "✓ No drift detected (hash1 matches). Webhook handles git changes (hash2)."
                return 0
            else
                echo "Drift detected (hash1 changed). Updating project..."

                if aws codebuild update-project --cli-input-json "$spec" --no-cli-pager >/dev/null; then
                    # Tag with new hash
                    local project_arn
                    project_arn=$(aws codebuild batch-get-projects \
                        --names "$project_name" \
                        --query 'projects[0].arn' \
                        --output text \
                        --no-cli-pager)
                    if ! aws resourcegroupstaggingapi tag-resources \
                        --resource-arn-list "$project_arn" \
                        --tags "DefinitionHash=$desired_hash" \
                        --no-cli-pager >/dev/null; then
                        echo "ERROR: Failed to tag CodeBuild project $project_name" >&2
                        return 1
                    fi

                    echo "✓ Project updated"

                    # Update webhook filter groups (idempotent)
                    local filter_groups
                    filter_groups=$(generate_webhook_filters "$cluster_type" "$GITHUB_BRANCH" "$ENVIRONMENT" "$REGION_DEPLOYMENT" "${REGIONAL_ID:-${MANAGEMENT_ID:-}}")

                    if retry_webhook_operation update-webhook --project-name "$project_name" --filter-groups "$filter_groups"; then
                        echo "✓ Webhook filters updated"
                    else
                        echo "ERROR: Failed to update webhook for $project_name" >&2
                        return 1
                    fi
                else
                    echo "ERROR: Failed to update project $project_name" >&2
                    return 1
                fi
            fi
        else
            # Project does not exist (batch-get returned null) - create it
            echo "Project does not exist. Creating..."

            if aws codebuild create-project --cli-input-json "$spec" --tags key=DefinitionHash,value="$desired_hash" --no-cli-pager >/dev/null; then
                echo "✓ Project created"

                # Create webhook
                local filter_groups
                filter_groups=$(generate_webhook_filters "$cluster_type" "$GITHUB_BRANCH" "$ENVIRONMENT" "$REGION_DEPLOYMENT" "${REGIONAL_ID:-${MANAGEMENT_ID:-}}")

                if retry_webhook_operation create-webhook --project-name "$project_name" --filter-groups "$filter_groups" --build-type BUILD; then
                    echo "✓ Webhook created"
                else
                    echo "ERROR: Failed to create webhook for $project_name" >&2
                    return 1
                fi

                # Day-1 first run: start a build with the current git SHA
                # Gated by SKIP_DAY1_BUILD — ephemeral provider owns StartBuild for RC/MC
                if [ "${SKIP_DAY1_BUILD:-false}" != "true" ]; then
                    local git_sha
                    git_sha=$(git rev-parse HEAD 2>/dev/null || echo "main")
                    echo "Starting Day-1 build at SHA: $git_sha"

                    if aws codebuild start-build --project-name "$project_name" --source-version "$git_sha" --no-cli-pager >/dev/null; then
                        echo "✓ Day-1 build started"
                    else
                        echo "WARNING: Failed to start Day-1 build (non-fatal)" >&2
                    fi
                else
                    echo "SKIP_DAY1_BUILD=true — skipping Day-1 StartBuild (provider will trigger)"
                fi
            else
                echo "ERROR: Failed to create project $project_name" >&2
                return 1
            fi
        fi
    else
        echo "ERROR: batch-get-projects failed for $project_name" >&2
        return 1
    fi
}

# Delete a CodeBuild project (idempotent)
delete_project() {
    local project_name="$1"

    echo "═══ Deleting CodeBuild project: $project_name ═══"

    # Delete webhook first (idempotent - ignores ResourceNotFoundException)
    if aws codebuild delete-webhook --project-name "$project_name" --no-cli-pager 2>/dev/null; then
        echo "✓ Webhook deleted"
    else
        echo "Webhook already deleted or does not exist (continuing)"
    fi

    # Delete project (idempotent)
    if aws codebuild delete-project --name "$project_name" --no-cli-pager 2>/dev/null; then
        echo "✓ Project deleted"
    else
        echo "Project already deleted or does not exist (continuing)"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Main Execution (preserves original flow)
# ──────────────────────────────────────────────────────────────────────────────

# Validate environment
ENVIRONMENT="${ENVIRONMENT:-${TARGET_ENVIRONMENT:-staging}}"

if [[ -z "$ENVIRONMENT" || ! "$ENVIRONMENT" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: ENVIRONMENT is empty or contains invalid characters: '${ENVIRONMENT}'" >&2
    exit 1
fi

# Ensure platform image exists (builds if missing, once before any create/update)
ensure_platform_image "$PLATFORM_IMAGE"

# Detect TF state region
TF_STATE_REGION=""
if [ -d "deploy/${ENVIRONMENT}" ]; then
    FIRST_REGIONAL_JSON=$(find "deploy/${ENVIRONMENT}" -name "regional-cluster.json" -path "*/codebuild-provisioner-inputs/*" -type f | head -n 1)
    if [ -n "$FIRST_REGIONAL_JSON" ]; then
        TF_STATE_REGION=$(jq -r '.tf_state_region // empty' "$FIRST_REGIONAL_JSON" 2>/dev/null || echo "")
    fi
fi

if [ -z "$TF_STATE_REGION" ]; then
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --region us-east-1 --query LocationConstraint --output text --no-cli-pager 2>/dev/null || echo "")
    if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ] || [ -z "$BUCKET_REGION" ]; then
        TF_STATE_REGION="us-east-1"
    else
        TF_STATE_REGION="$BUCKET_REGION"
    fi
fi

# FORCE_DELETE_ALL_PIPELINES CI hack
FORCE_DELETE_ALL_PIPELINES="${FORCE_DELETE_ALL_PIPELINES:-false}"
PROVISION_FAILURES=0

# ──────────────────────────────────────────────────────────────────────────────
# DNS Environment Zone (terraform block preserved)
# ──────────────────────────────────────────────────────────────────────────────

ENVIRONMENT_DOMAIN=""
ENVIRONMENT_HOSTED_ZONE_ID=""

for _first_region_dir in deploy/${ENVIRONMENT}/*/; do
    [ -d "$_first_region_dir" ] || continue
    _prov_tf="${_first_region_dir}codebuild-provisioner-inputs/terraform.json"
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

    # Retry helper inline (terraform still used for DNS zone)
    _max_attempts=3
    _attempt=1
    _wait_time=30
    while [ $_attempt -le $_max_attempts ]; do
        if terraform apply -auto-approve \
            -var="environment_domain=${ENVIRONMENT_DOMAIN}" \
            -var="environment=${ENVIRONMENT}"; then
            ENVIRONMENT_HOSTED_ZONE_ID=$(terraform output -raw zone_id)
            break
        fi
        if [ $_attempt -lt $_max_attempts ]; then
            echo "DNS zone apply attempt $_attempt failed, retrying in ${_wait_time}s..."
            sleep $_wait_time
            _wait_time=$((_wait_time * 2))
            _attempt=$((_attempt + 1))
        else
            echo "ERROR: Failed to create environment zone: $ENVIRONMENT_DOMAIN" >&2
            exit 1
        fi
    done

    cd ../../..
fi

# ──────────────────────────────────────────────────────────────────────────────
# Process regions
# ──────────────────────────────────────────────────────────────────────────────

if [ ! -d "deploy/${ENVIRONMENT}" ]; then
    echo "ERROR: Environment directory does not exist: deploy/${ENVIRONMENT}" >&2
    exit 1
fi

shopt -s nullglob
region_dirs=("deploy/${ENVIRONMENT}"/*/)
shopt -u nullglob

if [ ${#region_dirs[@]} -eq 0 ]; then
    echo "ERROR: No region directories found in deploy/${ENVIRONMENT}/" >&2
    exit 1
fi

for region_dir in deploy/${ENVIRONMENT}/*/; do
    [ -d "$region_dir" ] || continue

    REGION_DEPLOYMENT=$(basename "$region_dir")
    echo "Processing: $ENVIRONMENT / $REGION_DEPLOYMENT"

    # ── Regional Cluster ──────────────────────────────────────────────────────
    if [ -f "${region_dir}codebuild-provisioner-inputs/regional-cluster.json" ]; then
        REGIONAL_CONFIG="${region_dir}codebuild-provisioner-inputs/regional-cluster.json"

        AWS_REGION=$(jq -r '.region // .target_region // "us-east-1"' "$REGIONAL_CONFIG")
        TARGET_ACCOUNT_ID=$(jq -r '.account_id // ""' "$REGIONAL_CONFIG")
        TARGET_ACCOUNT_ID=$(resolve_ssm_param "$TARGET_ACCOUNT_ID" "$AWS_REGION")
        REGIONAL_ID=$(jq -r '.regional_id // ""' "$REGIONAL_CONFIG")

        export CHILD_ADMIN_ROLE_NAME
        CHILD_ADMIN_ROLE_NAME=$(jq -r '.child_admin_role_name // "OrganizationAccountAccessRole"' "$REGIONAL_CONFIG")

        if [[ "$CHILD_ADMIN_ROLE_NAME" != "OrganizationAccountAccessRole" && "$CHILD_ADMIN_ROLE_NAME" != "rosa-hyperfleet-account-admin" ]]; then
            echo "ERROR: Invalid child_admin_role_name: '${CHILD_ADMIN_ROLE_NAME}'" >&2
            exit 1
        fi

        DELETE_FLAG=$(jq -r '.delete_codebuild // false' "$REGIONAL_CONFIG")
        [ "$FORCE_DELETE_ALL_PIPELINES" == "true" ] && DELETE_FLAG="true"

        if [[ -z "$TARGET_ACCOUNT_ID" ]]; then
            echo "ERROR: account_id must be provided for region ${AWS_REGION}" >&2
            exit 1
        fi

        bootstrap_target_state_bucket "$TARGET_ACCOUNT_ID" "$AWS_REGION"

        # SDK upsert/delete (replaces terraform block)
        if [ "$DELETE_FLAG" == "true" ]; then
            delete_project "$REGIONAL_ID"
        else
            if ! upsert_project "regional" "$REGIONAL_ID" "$RC_CODEBUILD_ROLE_ARN" \
                "terraform/config/codebuild-regional-cluster/buildspec-combined.yml" 90; then
                echo "ERROR: Regional project upsert failed for ${REGIONAL_ID}" >&2
                PROVISION_FAILURES=$((PROVISION_FAILURES + 1))
            fi
        fi
    fi

    # ── Management Clusters ───────────────────────────────────────────────────
    shopt -s nullglob
    _mc_configs=(${region_dir}codebuild-provisioner-inputs/management-cluster-*.json)
    shopt -u nullglob
    if [ ${#_mc_configs[@]} -gt 0 ]; then
        for mc_config in ${region_dir}codebuild-provisioner-inputs/management-cluster-*.json; do
            [ -e "$mc_config" ] || continue

            _mc_basename=$(basename "$mc_config" .json)
            CLUSTER_NAME="${_mc_basename#management-cluster-}"

            AWS_REGION=$(jq -r '.region // .target_region // "us-east-1"' "$mc_config")
            TARGET_ACCOUNT_ID=$(jq -r '.account_id // ""' "$mc_config")
            TARGET_ACCOUNT_ID=$(resolve_ssm_param "$TARGET_ACCOUNT_ID" "$AWS_REGION")
            MANAGEMENT_ID=$(jq -r '.management_id // ""' "$mc_config")

            export CHILD_ADMIN_ROLE_NAME
            CHILD_ADMIN_ROLE_NAME=$(jq -r '.child_admin_role_name // "OrganizationAccountAccessRole"' "$mc_config")

            if [[ "$CHILD_ADMIN_ROLE_NAME" != "OrganizationAccountAccessRole" && "$CHILD_ADMIN_ROLE_NAME" != "rosa-hyperfleet-account-admin" ]]; then
                echo "ERROR: Invalid child_admin_role_name: '${CHILD_ADMIN_ROLE_NAME}'" >&2
                exit 1
            fi

            DELETE_FLAG=$(jq -r '.delete_codebuild // false' "$mc_config")
            [ "$FORCE_DELETE_ALL_PIPELINES" == "true" ] && DELETE_FLAG="true"

            if [[ -z "$TARGET_ACCOUNT_ID" ]]; then
                echo "ERROR: account_id must be provided for management cluster ${CLUSTER_NAME}" >&2
                exit 1
            fi

            bootstrap_target_state_bucket "$TARGET_ACCOUNT_ID" "$AWS_REGION"

            # SDK upsert/delete (replaces terraform block)
            if [ "$DELETE_FLAG" == "true" ]; then
                delete_project "$MANAGEMENT_ID"
            else
                if ! upsert_project "management" "$MANAGEMENT_ID" "$MC_CODEBUILD_ROLE_ARN" \
                    "terraform/config/codebuild-management-cluster/buildspec-combined.yml" 180; then
                    echo "ERROR: Management project upsert failed for ${MANAGEMENT_ID}" >&2
                    PROVISION_FAILURES=$((PROVISION_FAILURES + 1))
                fi
            fi
        done
    fi

done

if [ "$PROVISION_FAILURES" -gt 0 ]; then
    echo "ERROR: Pipeline provisioning completed with $PROVISION_FAILURES failure(s)" >&2
    exit 1
fi

echo "✓ Pipeline provisioning complete"
