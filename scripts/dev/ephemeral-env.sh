#!/usr/bin/env bash
#
# Ephemeral environment CLI for ROSA Regional Platform.
#
# Manages ephemeral developer environments in shared dev AWS accounts.
# Wraps the ephemeral provider (ci/ephemeral-provider/) with credential
# fetching, container execution, and local state tracking.
#
# Typically invoked via Makefile targets (make ephemeral-provision, etc.)
# but can be run directly: ./ci/ephemeral-env.sh provision --branch my-feature
#
# See docs/development-environment.md for full usage guide.

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"
CI_IMAGE="rosa-regional-ci"
ENVS_FILE=".ephemeral-envs"

VAULT_ADDR="https://vault.ci.openshift.org"
VAULT_KV_MOUNT="kv"
VAULT_SECRET_PATH="selfservice/cluster-secrets-rosa-regional-platform-int/ephemeral-shared-dev-creds"
VAULT_CRED_KEYS=(
    central_access_key central_secret_key central_assume_role_arn
    regional_access_key regional_secret_key
    management_access_key management_secret_key
    github_token
)

# =============================================================================
# Helpers
# =============================================================================

die() { echo "Error: $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  provision       Provision an ephemeral environment"
    echo "  teardown        Tear down an ephemeral environment"
    echo "  resync          Resync an ephemeral environment to your branch"
    echo "  swap-branch     Swap an ephemeral environment to a different branch"
    echo "  list            List ephemeral environments"
    echo "  shell           Interactive shell for Platform API access"
    echo "  bastion         Connect to RC/MC bastion in an ephemeral env"
    echo "  port-forward    Forward ports through RC/MC bastion in an ephemeral env"
    echo "  e2e             Run e2e tests against an ephemeral env"
    echo "  collect-logs    Collect kubernetes logs from RC/MC in an ephemeral env"
}

usage_bastion_interactive() {
    echo "Usage: $0 bastion --cluster-type [value]"
    echo ""
    echo "Connect to RC/MC bastion in an ephemeral environment"
    echo ""
    echo "Flags:"
    echo "  --cluster-type  Defines which cluster type to connect to. Accepted values are \"regional\" or \"management\""
}

usage_port_forward() {
    echo "Usage: $0 port-forward --cluster-type [value] <additional flags>"
    echo ""
    echo "Opens Port Forwards to the various services that are running on a cluster in the ephemeral env"
    echo ""
    echo "Flags:"
    echo "  --all           Automatically open all port forwards to the various services"
    echo "  --cluster-type  Defines which cluster type to connect to. Accepted values are \"regional\" or \"management\""
}

# Extract a KEY=VALUE field from an .ephemeral-envs line.
# Uses a space prefix to match exact keys (e.g. BRANCH vs EPH_BRANCH).
get_field() {
    echo "$1" | sed -n "s/.* ${2}=\([^ ]*\).*/\1/p"
}

# Update the STATE field for a BUILD_ID in .ephemeral-envs.
update_state() {
    local id="$1" new_state="$2"
    grep -v "^${id} " "$ENVS_FILE" > "${ENVS_FILE}.tmp" || true
    grep "^${id} " "$ENVS_FILE" \
        | sed "s/STATE=[^ ]*/STATE=${new_state}/" >> "${ENVS_FILE}.tmp"
    mv "${ENVS_FILE}.tmp" "$ENVS_FILE"
}

# Append KEY=VALUE to a BUILD_ID's line in .ephemeral-envs.
append_field() {
    local id="$1" key="$2" value="$3"
    sed "s|^${id} .*|& ${key}=${value}|" "$ENVS_FILE" > "${ENVS_FILE}.tmp" \
        && mv "${ENVS_FILE}.tmp" "$ENVS_FILE"
}

# Update one or more KEY=VALUE fields (update existing or append).
# Usage: update_fields <id> KEY1=VAL1 [KEY2=VAL2 ...]
update_fields() {
    local id="$1"; shift
    cp "$ENVS_FILE" "${ENVS_FILE}.tmp"
    for pair in "$@"; do
        local key="${pair%%=*}" value="${pair#*=}"
        if grep "^${id} " "${ENVS_FILE}.tmp" | grep -q " ${key}="; then
            sed -i.bak "/^${id} /s| ${key}=[^ ]*| ${key}=${value}|" "${ENVS_FILE}.tmp"
        else
            sed -i.bak "s|^${id} .*|& ${key}=${value}|" "${ENVS_FILE}.tmp"
        fi
    done
    rm -f "${ENVS_FILE}.tmp.bak"
    mv "${ENVS_FILE}.tmp" "$ENVS_FILE"
}

# Derive the ephemeral branch name from an env ID and branch name.
# Must match the Python logic in ci/ephemeral-provider/git.py and main.py.
derive_eph_branch() {
    local env_id="$1" branch="$2"
    echo "eph-${env_id}-$(echo "$branch" | tr '/' '-')-ci"
}

# Interactive fzf picker for remote + branch.
# Sets globals: PICKED_REPO, PICKED_BRANCH
pick_remote_branch() {
    local prompt="${1:-Select branch:}"

    local remote
    remote=$(git remote -v | grep '(fetch)' \
        | awk '{printf "%-15s %s\n", $1, $2}' \
        | fzf --height=10 --header="Select remote:" \
        | awk '{print $1}') \
        || { echo "Aborted."; exit 1; }

    PICKED_REPO=$(git remote get-url "$remote" | sed 's|.*github\.com[:/]||; s|\.git$||')
    echo "Fetching branches from $remote ($PICKED_REPO)..."

    PICKED_BRANCH=$(git ls-remote --heads "$remote" 2>/dev/null \
        | sed 's|.*refs/heads/||' \
        | fzf --height=20 --header="$prompt") \
        || { echo "Aborted."; exit 1; }
}

# Select an environment by explicit ID or interactive fzf picker.
# Sets global: BUILD_ID, ENV_LINE
#   $1 = grep pattern to filter candidates
#   $2 = fzf header text
#   $3 = "no match" message
#   $4 = bool - auto select the only result if this is true
select_env() {
    local state_filter="$1" header="$2" no_match_msg="$3" auto_select_single=${4:-false}

    if [[ -n "${ID:-}" ]]; then
        BUILD_ID="$ID"
    else
        command -v fzf >/dev/null 2>&1 \
            || die "fzf is required for interactive selection. Install fzf or pass ID=<id> directly."
        [[ -f "$ENVS_FILE" && -s "$ENVS_FILE" ]] \
            || die "No environments found in $ENVS_FILE."

        local candidates
        candidates=$(grep -E "$state_filter" "$ENVS_FILE" || true)
        [[ -n "$candidates" ]] || die "$no_match_msg"

        local selected
        local candidate_count=$(wc -l <<< "$candidates")

        if [ $auto_select_single == true ] && [ $candidate_count -eq 1 ]; then
            selected="$candidates"
            BUILD_ID=$(echo "$selected" | awk '{print $1}')
            echo "Only one ready environment found. Defaulting to: $BUILD_ID"
        else
            selected=$(echo "$candidates" | fzf --height=20 --header="$header") \
                || { echo "Aborted."; exit 1; }
            BUILD_ID=$(echo "$selected" | awk '{print $1}')
        fi
    fi

    ENV_LINE=$(grep "^${BUILD_ID} " "$ENVS_FILE" 2>/dev/null) \
        || die "ID $BUILD_ID not found in $ENVS_FILE."
}

fzf_pick() {
  local header="$1"
  shift
  printf '%s\n' "$@" | fzf --multi --height=10 --layout=reverse --header="$header" --no-info
}

# Check if .ephemeral-env/ override directory exists.
# Sets global: OVERRIDE_MOUNT (container flags), OVERRIDE_INFO (display string)
setup_override_mount() {
    OVERRIDE_MOUNT=""
    OVERRIDE_INFO="(default)"
    if [[ -d "${REPO_ROOT}/.ephemeral-env" ]]; then
        OVERRIDE_MOUNT="-v ${REPO_ROOT}/.ephemeral-env:/overrides:ro,z -e EPHEMERAL_OVERRIDE_DIR=/overrides"
        OVERRIDE_INFO=".ephemeral-env/"
    fi
}

# Fetch credentials from Vault via OIDC login, or use pre-set env vars.
# Sets global: CRED_FLAGS (container -e flags), REGIONAL_AK, REGIONAL_SK,
#              MANAGEMENT_AK, MANAGEMENT_SK
# Credentials never touch disk — they live only in this shell process.
fetch_creds() {
    CRED_FLAGS=""
    REGIONAL_AK=""
    REGIONAL_SK=""
    MANAGEMENT_AK=""
    MANAGEMENT_SK=""

    # If all credential env vars are already set, skip Vault entirely.
    local all_set=true
    local missing_keys=""
    for key in "${VAULT_CRED_KEYS[@]}"; do
        local upper_key
        upper_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
        if [[ -z "${!upper_key:-}" ]]; then
            all_set=false
            missing_keys="$missing_keys $upper_key"
        fi
    done

    if [[ "$all_set" == "true" ]]; then
        echo "Using pre-set credentials from environment."
        for key in "${VAULT_CRED_KEYS[@]}"; do
            local upper_key
            upper_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
            local val="${!upper_key}"
            CRED_FLAGS="$CRED_FLAGS -e ${upper_key}=${val}"

            case "$key" in
                regional_access_key)    REGIONAL_AK="$val" ;;
                regional_secret_key)    REGIONAL_SK="$val" ;;
                management_access_key)  MANAGEMENT_AK="$val" ;;
                management_secret_key)  MANAGEMENT_SK="$val" ;;
            esac
        done
        echo "Credentials loaded from environment."
        return
    fi

    echo "Missing credential env vars:$missing_keys"
    echo "Fetching credentials from Vault (OIDC login)..."

    local vault_token
    vault_token=$(VAULT_ADDR="$VAULT_ADDR" vault login -method=oidc -token-only 2>/dev/null) \
        || die "Vault OIDC login failed."

    for key in "${VAULT_CRED_KEYS[@]}"; do
        local val
        val=$(VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$vault_token" \
            vault kv get -mount="$VAULT_KV_MOUNT" -field="$key" "$VAULT_SECRET_PATH" 2>/dev/null) \
            || die "Failed to fetch credential '$key' from Vault."

        local upper_key
        upper_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
        CRED_FLAGS="$CRED_FLAGS -e ${upper_key}=${val}"

        case "$key" in
            regional_access_key)    REGIONAL_AK="$val" ;;
            regional_secret_key)    REGIONAL_SK="$val" ;;
            management_access_key)  MANAGEMENT_AK="$val" ;;
            management_secret_key)  MANAGEMENT_SK="$val" ;;
        esac
    done

    echo "Credentials loaded (in-memory only)."
}

# Initial bastion connectivity and setup
bastion_setup() {
    local cluster_type="${1:-}"

    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment for bastion access:" \
        "No ready environments found." \
        true

    local region
    region=$(get_field "$ENV_LINE" REGION)
    [[ -n "$region" ]] \
        || die "No REGION found for ID $BUILD_ID. Was it captured during provision?"

    # Compute eph_prefix from BUILD_ID (must match ci/ephemeral-provider/main.py)
    local eph_prefix="eph-${BUILD_ID}"

    # Derive cluster ID and ECS resource names from eph_prefix
    if [[ "$cluster_type" == "regional" ]]; then
        cluster_id="${eph_prefix}-regional"
    else
        cluster_id="${eph_prefix}-mc01"
    fi
    export ecs_cluster="${cluster_id}-bastion"

    # Fetch credentials from Vault
    fetch_creds

    # Select the right credentials for the target account
    local target_ak target_sk
    if [[ "$cluster_type" == "regional" ]]; then
        target_ak="$REGIONAL_AK"
        target_sk="$REGIONAL_SK"
    else
        target_ak="$MANAGEMENT_AK"
        target_sk="$MANAGEMENT_SK"
    fi

    echo "Connecting to ephemeral bastion..."
    echo "  ID:           $BUILD_ID"
    echo "  Eph prefix:   $eph_prefix"
    echo "  Cluster type: $cluster_type"
    echo "  Cluster ID:   $cluster_id"
    echo "  ECS cluster:  $ecs_cluster"
    echo "  Region:       $region"
    echo ""

    export AWS_ACCESS_KEY_ID="$target_ak"
    export AWS_SECRET_ACCESS_KEY="$target_sk"
    export AWS_DEFAULT_REGION="$region"
    export AWS_REGION="$region"

    # Check for an existing running task
    echo "==> Checking for running bastion tasks..."
    local existing_task
    existing_task=$(aws ecs list-tasks --cluster "$ecs_cluster" \
        --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null || true)

    if [[ -n "$existing_task" && "$existing_task" != "None" ]]; then
        export task_id=$(echo "$existing_task" | awk -F'/' '{print $NF}')
        echo "==> Found existing running task: $task_id"
    else
        echo "==> No running task found, starting a new one..."

        # Discover task definition, subnets, and security group from AWS
        local task_def="${cluster_id}-bastion"
        local sg_id subnets

        sg_id=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${cluster_id}-bastion" \
            --query 'SecurityGroups[0].GroupId' --output text) \
            || die "Could not find security group '${cluster_id}-bastion'."
        [[ "$sg_id" != "None" ]] \
            || die "Security group '${cluster_id}-bastion' not found."

        # Find private subnets tagged for the cluster's VPC
        local vpc_id
        vpc_id=$(aws ec2 describe-security-groups \
            --group-ids "$sg_id" \
            --query 'SecurityGroups[0].VpcId' --output text)

        subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*private*" \
            --query 'Subnets[].SubnetId' --output text \
            | tr '\t' ',') \
            || die "Could not find private subnets in VPC $vpc_id."

        echo "    Task def:  $task_def"
        echo "    SG:        $sg_id"
        echo "    Subnets:   $subnets"

        AWS_PAGER="" aws ecs run-task \
            --cluster "$ecs_cluster" \
            --task-definition "$task_def" \
            --launch-type FARGATE \
            --enable-execute-command \
            --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
            > /dev/null

        export task_id=$(aws ecs list-tasks --cluster "$ecs_cluster" \
            --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
    fi

    # Wait for task to be running
    echo "==> Waiting for task to be running..."
    aws ecs wait tasks-running --cluster "$ecs_cluster" --tasks "$task_id"

    # Wait for the ECS exec agent to be ready
    echo "==> Waiting for execute command agent..."
    local agent_status=""
    for i in $(seq 1 30); do
        agent_status=$(aws ecs describe-tasks \
            --cluster "$ecs_cluster" --tasks "$task_id" --output json \
            | jq -r '.tasks[0].containers[] | select(.name=="bastion") | .managedAgents[] | select(.name=="ExecuteCommandAgent") | .lastStatus' 2>/dev/null || true)
        if [[ "$agent_status" == "RUNNING" ]]; then
            break
        fi
        sleep 2
    done
    [[ "$agent_status" == "RUNNING" ]] \
        || die "Execute command agent did not become ready (status: ${agent_status:-unknown})"
}


# Build the CI container image if not already present.
ensure_image() {
    [[ -n "$CONTAINER_ENGINE" ]] \
        || die "No container engine found. Install podman or docker."

    if ! $CONTAINER_ENGINE image inspect "$CI_IMAGE" >/dev/null 2>&1; then
        echo "Building CI image..."
        local build_output
        if ! build_output=$($CONTAINER_ENGINE build -t "$CI_IMAGE" -f ci/Containerfile ci 2>&1); then
            echo "$build_output"
            die "Failed to build CI image."
        fi
    fi
}

# Check that required CLI tools are available.
preflight() {
    local missing=""
    for tool in vault git python3 fzf; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [[ -n "$CONTAINER_ENGINE" ]] || missing="$missing podman/docker"
    [[ -z "$missing" ]] || die "Missing required tools:$missing"
}

# =============================================================================
# Commands
# =============================================================================

cmd_provision() {
    local repo="${REPO:-openshift-online/rosa-regional-platform}"
    local branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

    # Generate an ID if not provided
    if [[ -z "${ID:-}" ]]; then
        ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
    fi

    # Interactive remote + branch picker (when BRANCH not explicitly set)
    if [[ -z "${BRANCH:-}" ]] && command -v fzf >/dev/null 2>&1; then
        echo "Current branch: $branch"
        echo "Select a remote to pick a branch from (or Esc to abort):"
        pick_remote_branch "Select branch:"
        repo="$PICKED_REPO"
        branch="$PICKED_BRANCH"
        echo "Selected branch: $branch (from $repo)"
    fi

    # Check for local config overrides
    setup_override_mount

    # Fetch credentials
    fetch_creds

    # Print summary
    echo "Provisioning ephemeral environment..."
    echo "  ID:                $ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  ENV CONFIG:        $OVERRIDE_INFO"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"

    # Record initial state
    echo "$ID REPO=$repo BRANCH=$branch STATE=provisioning CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$ENVS_FILE"

    # Run the ephemeral provider
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir:-}"' EXIT

    local rc=0
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $CRED_FLAGS \
        $OVERRIDE_MOUNT \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -v "${tmpdir}:/output:z" \
        -w /workspace \
        -e WORKSPACE_DIR=/workspace \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --id "$ID" \
            --repo "$repo" --branch "$branch" \
            --save-regional-state /output/tf-outputs.json \
    || rc=$?

    # Record results
    if [[ $rc -eq 0 ]]; then
        local api_url="" region=""
        if [[ -f "$tmpdir/tf-outputs.json" ]] && command -v jq >/dev/null 2>&1; then
            api_url=$(jq -r '.api_gateway_invoke_url.value // empty' "$tmpdir/tf-outputs.json" 2>/dev/null || true)
        fi
        if [[ -f "$tmpdir/region" ]]; then
            region=$(cat "$tmpdir/region")
        fi

        update_state "$ID" "ready"
        [[ -z "$region" ]]  || append_field "$ID" "REGION" "$region"
        [[ -z "$api_url" ]] || append_field "$ID" "API_URL" "$api_url"

        # Store ephemeral branch name so it survives branch swaps
        append_field "$ID" "EPH_BRANCH" "$(derive_eph_branch "$ID" "$branch")"

        echo ""
        echo "Environment recorded in $ENVS_FILE."
        [[ -z "$api_url" ]] || echo -e "\n  API Gateway:  $api_url"
        echo ""
        echo "  To interact with the API:"
        echo "    make ephemeral-shell ID=$ID"
        echo ""
        echo "  To run e2e tests:"
        echo "    make ephemeral-e2e ID=$ID"
        echo ""
        echo "  To tear down:"
        echo "    make ephemeral-teardown ID=$ID"
    else
        update_state "$ID" "provisioning-failed"
        echo "Provisioning failed. State updated to provisioning-failed."
        exit $rc
    fi
}

cmd_teardown() {
    # Select environment
    select_env "STATE=(provisioning|ready|provisioning-failed|deprovisioning|deprovisioning-failed)" \
        "Select environment to tear down:" \
        "No active environments found."

    local repo branch region eph_branch
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)
    region=$(get_field "$ENV_LINE" REGION)
    eph_branch=$(get_field "$ENV_LINE" EPH_BRANCH)

    # Fetch credentials
    fetch_creds

    # Build --eph-branch flag if available (needed after swap-branch)
    local eph_branch_flag=""
    [[ -z "$eph_branch" ]] || eph_branch_flag="--eph-branch $eph_branch"

    # Print summary
    echo "Tearing down ephemeral environment..."
    echo "  ID:                $BUILD_ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  REGION:            $region"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"

    # Run teardown
    update_state "$BUILD_ID" "deprovisioning"

    local rc=0
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $CRED_FLAGS \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e WORKSPACE_DIR=/workspace \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --teardown --id "$BUILD_ID" --repo "$repo" --branch "$branch" \
            $eph_branch_flag \
    || rc=$?

    # Update state
    if [[ $rc -eq 0 ]]; then
        update_state "$BUILD_ID" "deprovisioned"
        echo "Environment $BUILD_ID deprovisioned."
    else
        update_state "$BUILD_ID" "deprovisioning-failed"
        echo "Teardown failed. State updated to deprovisioning-failed."
        exit $rc
    fi
}

cmd_resync() {
    # Select environment
    select_env "STATE=(provisioning|ready|provisioning-failed|deprovisioning|deprovisioning-failed)" \
        "Select environment to resync:" \
        "No active environments found."

    local repo branch eph_branch
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)
    eph_branch=$(get_field "$ENV_LINE" EPH_BRANCH)

    # Check for local config overrides
    setup_override_mount

    # Fetch credentials
    fetch_creds

    # Build --eph-branch flag if available (needed after swap-branch)
    local eph_branch_flag=""
    [[ -z "$eph_branch" ]] || eph_branch_flag="--eph-branch $eph_branch"

    # Print summary
    echo "Resyncing ephemeral environment..."
    echo "  ID:                $BUILD_ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  ENV CONFIG:        $OVERRIDE_INFO"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"

    # Run resync
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $CRED_FLAGS \
        $OVERRIDE_MOUNT \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e WORKSPACE_DIR=/workspace \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --resync --id "$BUILD_ID" --repo "$repo" --branch "$branch" \
            $eph_branch_flag
}

cmd_swap_branch() {
    local new_branch="${NEW_BRANCH:-}"
    local new_repo="${NEW_REPO:-}"

    # Select environment
    select_env "STATE=ready" \
        "Select environment to swap branch:" \
        "No ready environments found."

    local repo branch eph_branch
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)
    eph_branch=$(get_field "$ENV_LINE" EPH_BRANCH)

    # Compute EPH_BRANCH for pre-existing envs that don't have it yet
    [[ -n "$eph_branch" ]] || eph_branch=$(derive_eph_branch "$BUILD_ID" "$branch")

    # Interactive branch picker if NEW_BRANCH not set
    if [[ -z "$new_branch" ]] && command -v fzf >/dev/null 2>&1; then
        echo "Current: $branch (repo: $repo)"
        echo "Select a remote to pick a new branch from (or Esc to abort):"
        pick_remote_branch "Select branch to swap to:"
        new_repo="$PICKED_REPO"
        new_branch="$PICKED_BRANCH"
        echo "Selected: $new_branch (from $new_repo)"
    elif [[ -z "$new_branch" ]]; then
        die "NEW_BRANCH is required. Usage: make ephemeral-swap-branch NEW_BRANCH=<branch> [NEW_REPO=<owner/repo>]"
    fi

    # Default new_repo to the current repo if not specified
    [[ -n "$new_repo" ]] || new_repo="$repo"

    # Skip if already on the target branch
    if [[ "$new_repo" == "$repo" && "$new_branch" == "$branch" ]]; then
        echo "Already on $repo @ $branch. Nothing to do."
        return
    fi

    echo ""
    echo "Swapping ephemeral environment branch..."
    echo "  ID:      $BUILD_ID"
    echo "  FROM:    $repo @ $branch"
    echo "  TO:      $new_repo @ $new_branch"

    # Update .ephemeral-envs with new branch/repo and persist EPH_BRANCH (single write)
    update_fields "$BUILD_ID" "REPO=$new_repo" "BRANCH=$new_branch" "EPH_BRANCH=$eph_branch"

    # Resync to the new branch
    ID="$BUILD_ID" cmd_resync
}

cmd_list() {
    if [[ ! -f "$ENVS_FILE" || ! -s "$ENVS_FILE" ]]; then
        echo "No ephemeral environments."
        return
    fi

    echo "Ephemeral environments:"
    echo ""
    printf "%-12s %-45s %-25s %-12s %-22s %-20s %s\n" \
        "ID" "REPO" "BRANCH" "REGION" "STATE" "CREATED" "API_URL"
    echo "------------ --------------------------------------------- ------------------------- ------------ ---------------------- -------------------- -------"

    while IFS= read -r line; do
        local build_id repo branch region state created api_url
        build_id=$(echo "$line" | awk '{print $1}')
        repo=$(get_field "$line" REPO)
        branch=$(get_field "$line" BRANCH)
        region=$(get_field "$line" REGION)
        state=$(get_field "$line" STATE)
        created=$(get_field "$line" CREATED)
        api_url=$(get_field "$line" API_URL)
        printf "%-12s %-45s %-25s %-12s %-22s %-20s %s\n" \
            "$build_id" "$repo" "$branch" "$region" "$state" "$created" "$api_url"
    done < "$ENVS_FILE"

    echo ""
    echo "To clear list: rm $ENVS_FILE"
}

cmd_shell() {
    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment:" \
        "No ready environments found." \
        true

    local api_url region
    api_url=$(get_field "$ENV_LINE" API_URL)
    region=$(get_field "$ENV_LINE" REGION)

    # Fetch credentials
    fetch_creds

    # Launch interactive shell
    $CONTAINER_ENGINE run --rm -it \
        -e "AWS_ACCESS_KEY_ID=$REGIONAL_AK" \
        -e "AWS_SECRET_ACCESS_KEY=$REGIONAL_SK" \
        -e "AWS_DEFAULT_REGION=$region" \
        -e "AWS_REGION=$region" \
        -e "API_URL=$api_url" \
        "$CI_IMAGE" \
        bash -c '
            echo ""
            echo "ROSA Regional Platform shell"
            echo ""
            echo "API Gateway: $API_URL"
            echo "Region:      $AWS_DEFAULT_REGION"
            echo ""
            echo "Example commands:"
            echo "  awscurl --service execute-api $API_URL/v0/live"
            exec bash'
}

cmd_bastion_interactive() {
    local cluster_type

    while [ "${1:-}" != "" ]; do
        case $1 in
            --cluster-type )        cluster_type=${2:-}
                                    shift
                                    ;;
            --help )                usage_bastion_interactive
                                    exit 0
                                    ;;
            * ) echo "Unexpected parameter $1"
                usage
                exit 1
        esac
        shift
    done

    case "$cluster_type" in
      regional|management) ;;
      *) echo "Error: invalid cluster type '$cluster_type'"; echo ""; usage_bastion_interactive; exit 1 ;;
    esac

    bastion_setup $cluster_type

    ## Leave these here so we can ensure that the variables
    ## are actually available since we refactored out the logic
    echo ""
    echo "==> Bastion task ready"
    echo "    ECS cluster: $ecs_cluster"
    echo "    Task ID:     $task_id"
    echo ""
    echo "==> Connecting to bastion..."
    echo ""

    # Connect via ECS Exec
    aws ecs execute-command \
        --cluster "$ecs_cluster" \
        --task "$task_id" \
        --container bastion \
        --interactive \
        --command '/bin/bash'
}

cmd_bastion_port_forward() {
    local all_svcs=false
    local cluster_type

    while [ "${1:-}" != "" ]; do
    case $1 in
        --all )                 all_svcs=true
                                ;;
        --cluster-type )        cluster_type=${2:-}
                                shift
                                ;;
        --help )                usage_port_forward
                                exit 0
                                ;;
        * ) echo "Unexpected parameter $1"
            usage
            exit 1
    esac
    shift
    done

    # --- Validations ------------------------
    case "$cluster_type" in
      regional|management) ;;
      *) echo "Error: invalid cluster type '$cluster_type'"; echo ""; usage_port_forward; exit 1 ;;
    esac

    local maestro="maestro   - Maestro HTTP + gRPC"
    local argocd="argocd    - ArgoCD server HTTPS"
    local prometheus="prometheus  - Prometheus Monitoring Dashboard"
    local thanos="thanos    - Thanos Query Frontend (aggregated RC+MC metrics)"
    local alertmanager="alertmanager - AlertManager Web UI"
    local grafana="grafana   - Grafana Dashboard"
    local custom="custom    - Custom service / ports"

    # custom services are added only for interactive
    local regional_svc_list=("$maestro" "$argocd" "$prometheus" "$thanos" "$alertmanager" "$grafana")
    local management_svc_list=("$argocd" "$prometheus")

    local services

    # If we provide the all-services flag, set all the services
    if [ $all_svcs == true ]; then
        case "$cluster_type" in
            regional )      services=$(printf '%s\n' "${regional_svc_list[@]}") ;;
            management )    services=$(printf '%s\n' "${management_svc_list[@]}") ;;
        esac
    else
        # otherwise, prompt the user
        if [ "$cluster_type" = "regional" ]; then
            services=$(fzf_pick "Select service (${cluster_type}):" "${regional_svc_list[@]}" "$custom")
        else
            services=$(fzf_pick "Select service (${cluster_type}):" "${management_svc_list[@]}" "$custom")
        fi
    fi
    services=$(awk '{print $1}' <<< "$services")

    local forwards=()
    for service in $services
    do
        if [ "$service" = "maestro" ] && [ "$cluster_type" != "regional" ]; then
            echo "Error: maestro is only available on regional clusters."
            exit 1
        fi

        # ── Build port-forward definitions ───────────────────────────────────────────
        # Each entry: "label remote_port local_port k8s_svc k8s_namespace k8s_svc_port"

        case "$service" in
        maestro)
            forwards+=(
            "Maestro-HTTP 8080 8080 maestro-http maestro-server 8080"
            "Maestro-gRPC 8090 8090 maestro-grpc maestro-server 8090"
            )
            ;;
        argocd)
            forwards+=(
            "ArgoCD-Server 8443 8443 argocd-server argocd 443"
            )
            ;;
        prometheus)
            forwards+=(
            "Prometheus 9090 9090 monitoring-prometheus monitoring 9090"
            )
            ;;
        thanos)
            forwards+=(
            "Thanos-Query 10902 10902 thanos-query-frontend-thanos-query thanos 9090"
            ;;
        alertmanager)
            forwards+=(
            "AlertManager 9093 9093 monitoring-alertmanager monitoring 9093"
            )
            ;;
        grafana)
            forwards+=(
            "Grafana 3000 3000 grafana grafana 80"
            )
            ;;
        custom)
            local k8s_ns k8s_svc k8s_svc_port local_port remote_port
            echo ""
            read -rp "Kubernetes namespace: " k8s_ns
            read -rp "Service name (without svc/ prefix): " k8s_svc
            read -rp "Service port [443]: " k8s_svc_port
            k8s_svc_port="${k8s_svc_port:-443}"
            read -rp "Local port [${k8s_svc_port}]: " local_port
            local_port="${local_port:-$k8s_svc_port}"
            remote_port="$local_port"

            forwards+=(
            "Custom ${remote_port} ${local_port} ${k8s_svc} ${k8s_ns} ${k8s_svc_port}"
            )
            ;;
        *) echo "Error: unknown service '$service'"; echo ""; usage; exit 1 ;;
        esac
    done

    # ── Pre-flight: check local ports are free ───────────────────────────────────

    for entry in "${forwards[@]}"; do
        local local_port
        read -r label _ local_port _ _ _ <<< "$entry"
        if lsof -iTCP:"$local_port" -sTCP:LISTEN -t &>/dev/null; then
            echo "Error: Local port ${local_port} (${label}) is already in use."
            echo "Kill the process using it first: lsof -iTCP:${local_port} -sTCP:LISTEN"
            exit 1
        fi
    done

    # ── Connect to Bastion ──────────────────────────────────────────────────────

    bastion_setup $cluster_type

    local runtime_id
    runtime_id=$(aws ecs describe-tasks \
      --cluster "$ecs_cluster" \
      --tasks "$task_id" \
      --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' \
      --output text)

    if [[ -z "$runtime_id" || "$runtime_id" == "None" ]]; then
      echo "Error: runtime_id not found for task '$task_id' in cluster '$ecs_cluster'"
      exit 1
    fi

    echo ""
    echo "==> Bastion task ready"
    echo "    ECS cluster: $ecs_cluster"
    echo "    Task ID:     $task_id"
    echo ""
    echo "==> Connecting to bastion..."
    echo ""

    # ── Port forwarding ─────────────────────────────────────────────────────────

    ssm_pids=()

    cleanup() {
    echo ""
    echo "Stopping all port-forward sessions..."
    for pid in "${ssm_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    }
    trap cleanup EXIT

    target="ecs:${ecs_cluster}_${task_id}_${runtime_id}"

    # Kill stale port-forwards on bastion
    echo "==> Cleaning up stale port-forwards on bastion..."
    aws ecs execute-command \
    --cluster "$ecs_cluster" \
    --task "$task_id" \
    --container bastion \
    --interactive \
    --command "pkill -f kubectl.port-forward || true" &>/dev/null || true
    sleep 2

    # Start kubectl port-forward(s) inside the bastion (one ECS exec per forward).
    # The ECS exec session is short-lived but kubectl keeps running in the container.
    for entry in "${forwards[@]}"; do
        read -r label remote_port local_port k8s_svc k8s_ns k8s_svc_port <<< "$entry"

        echo "==> [bastion] kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns}"
        aws ecs execute-command \
            --cluster "$ecs_cluster" \
            --task "$task_id" \
            --container bastion \
            --interactive \
            --command "kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns} --address 0.0.0.0" &
    done
    # Not tracked in SSM_PIDS — the ECS exec processes are expected to exit

    # Wait for kubectl to bind inside the bastion
    echo ""
    echo "==> Waiting for kubectl port-forward(s) to be ready..."
    sleep 5

    # Hop 2: SSM port forward from laptop to bastion
    for entry in "${forwards[@]}"; do
        read -r label remote_port local_port _ _ _ <<< "$entry"

        echo "==> [local] SSM forwarding ${label} (localhost:${local_port} -> bastion:${remote_port})..."
        aws ssm start-session \
            --target "$target" \
            --document-name AWS-StartPortForwardingSession \
            --parameters "{\"portNumber\":[\"${remote_port}\"],\"localPortNumber\":[\"${local_port}\"]}" &
        ssm_pids+=($!)
    done

    echo ""
    echo "==> Port forwarding active. Forwarded ports:"
    for entry in "${forwards[@]}"; do
        read -r label _ local_port _ _ _ <<< "$entry"
        echo "    ${label}: http://localhost:${local_port}"
    done

    # For ArgoCD, fetch and display the admin password from the bastion.
    # Use a marker prefix so we can extract the password from the SSM session noise.
    if [[ " $services " =~ " argocd " ]]; then
        echo ""
        echo "==> Fetching ArgoCD admin password..."
        argocd_get_password=$(aws ecs execute-command \
            --cluster "$ecs_cluster" \
            --task "$task_id" \
            --container bastion \
            --interactive \
            --command "sh -c \"echo ARGOCD_PW=\$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d)\"" 2>/dev/null || true)
        argocd_password=$(echo "$argocd_get_password" | grep -o 'ARGOCD_PW=.*' | cut -d= -f2 | tr -d '[:space:]')
        echo ""
        echo "    ArgoCD UI:       https://localhost:8443"
        echo "    Username:        admin"
        if [ -n "$argocd_password" ]; then
            echo "    Password:        ${argocd_password}"
        else
            echo "    Password:        (could not retrieve - run on bastion manually):"
            echo "                     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d"
        fi
    fi

    echo ""
    echo "Press Ctrl+C to stop."

    # Wait for any SSM session to exit — if one dies, tear everything down
    while true; do
    for pid in "${ssm_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        echo ""
        echo "Error: SSM port-forward session (PID $pid) exited unexpectedly."
        exit 1
        fi
    done
    sleep 2
    done
}

cmd_e2e() {
    local e2e_ref="${E2E_REF:-main}"
    local e2e_repo="${E2E_REPO:-https://github.com/openshift-online/rosa-regional-platform-api.git}"

    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment for e2e tests:" \
        "No ready environments found."

    local api_url region
    api_url=$(get_field "$ENV_LINE" API_URL)
    region=$(get_field "$ENV_LINE" REGION)
    [[ -n "$api_url" ]] \
        || die "No API_URL found for ID $BUILD_ID. Was it captured during provision?"

    # Fetch credentials
    fetch_creds

    # Run tests
    echo "Running e2e tests..."
    echo "  ID:         $BUILD_ID"
    echo "  API_URL:    $api_url"
    echo "  REGION:     $region"
    echo "  E2E_REF:    $e2e_ref"
    echo "  E2E_REPO:   $e2e_repo"

    $CONTAINER_ENGINE run --rm \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e "BASE_URL=$api_url" \
        -e "AWS_ACCESS_KEY_ID=$REGIONAL_AK" \
        -e "AWS_SECRET_ACCESS_KEY=$REGIONAL_SK" \
        -e "AWS_DEFAULT_REGION=$region" \
        -e "AWS_REGION=$region" \
        -e "E2E_REF=$e2e_ref" \
        -e "E2E_REPO=$e2e_repo" \
        "$CI_IMAGE" \
        bash ci/e2e-tests.sh
}

cmd_collect_logs() {
    local cluster_type="${1:-all}"
    # Accept short aliases
    case "$cluster_type" in
        rc) cluster_type="regional" ;;
        mc) cluster_type="management" ;;
    esac
    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment for log collection:" \
        "No ready environments found." \
        true

    fetch_creds

    local region
    region=$(get_field "$ENV_LINE" REGION)

    local eph_prefix
    eph_prefix="eph-${BUILD_ID}-"

    export REGIONAL_AK REGIONAL_SK MANAGEMENT_AK MANAGEMENT_SK
    export AWS_REGION="$region"
    export CLUSTER_PREFIX="$eph_prefix"
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        export LOG_OUTPUT_DIR="$ARTIFACT_DIR"
    fi

    "${REPO_ROOT}/scripts/dev/collect-cluster-logs.sh" "$cluster_type"
}

# =============================================================================
# Main
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Commands that don't need preflight or container image
case "${1:-help}" in
    list) cmd_list; exit 0 ;;
esac

# Bastion needs vault + aws but not container engine
case "${1:-help}" in
    bastion|collect-logs)
        for tool in vault aws; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    port-forward)
        for tool in vault aws fzf lsof; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    *)
        # All other commands need tools + container image
        preflight
        ensure_image
        ;;
esac

case "${1:-help}" in
    provision)      cmd_provision ;;
    teardown)       cmd_teardown ;;
    resync)         cmd_resync ;;
    swap-branch)    cmd_swap_branch ;;
    shell)          cmd_shell ;;
    bastion)        shift; cmd_bastion_interactive "$@" ;;
    port-forward)   shift; cmd_bastion_port_forward "$@" ;;
    e2e)            cmd_e2e ;;
    collect-logs)   shift; cmd_collect_logs "$@" ;;
    help|*)
        usage
        ;;
esac
