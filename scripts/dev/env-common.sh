#!/usr/bin/env bash
#
# Shared utilities for ROSA Regional Platform dev environment scripts.
#
# Sourced by ephemeral-env.sh and int-env.sh. Not executable on its own.
#
# Functions provided:
#   die                   — Print error and exit
#   resolve_creds         — Resolve AWS profile to static credentials
#   ensure_image          — Build CI container image if not present
#   load_accounts         — Load account IDs from a JSON file
#   init_aws_config       — Create temp AWS config dir + EXIT trap
#   write_container_config — Resolve profiles to static creds for container mount
#   bastion_run_task      — Core ECS bastion task launch and readiness logic

# Sourcing scripts should set these before sourcing:
#   CONTAINER_ENGINE, CI_IMAGE

die() { echo "Error: $*" >&2; exit 1; }

# Resolve the base SAML credentials from a credential_process profile.
# The credential_process is not cached by the AWS CLI, so this always returns
# fresh credentials. Results are cached in-process for the given profile.
# Args: $1 = base profile name (the one with credential_process)
# Sets: _BASE_AK, _BASE_SK, _BASE_ST
resolve_base_creds() {
    local base_profile="$1"
    if [[ "${_BASE_RESOLVED_PROFILE:-}" == "$base_profile" ]]; then
        return 0
    fi
    echo "Resolving base credentials..."
    local creds creds_err
    creds_err=$(mktemp)
    creds=$(aws configure export-credentials --profile "$base_profile" --format process 2>"$creds_err") \
        || { local err; err=$(<"$creds_err"); rm -f "$creds_err"; die "Failed to resolve base credentials ($base_profile):\n$err"; }
    rm -f "$creds_err"
    _BASE_AK=$(echo "$creds" | jq -r '.AccessKeyId')
    _BASE_SK=$(echo "$creds" | jq -r '.SecretAccessKey')
    _BASE_ST=$(echo "$creds" | jq -r '.SessionToken // empty')
    _BASE_RESOLVED_PROFILE="$base_profile"
}

# Assume a role using the base SAML credentials, bypassing the CLI's profile cache.
# Reads source_profile and role_arn from the given profile config.
# Sets: _CRED_AK, _CRED_SK, _CRED_ST
resolve_creds() {
    local profile="$1"
    echo "Resolving credentials for profile $profile..."

    local role_arn base_profile
    role_arn=$(aws configure get role_arn --profile "$profile" 2>/dev/null) \
        || die "No role_arn found for profile $profile"
    base_profile=$(aws configure get source_profile --profile "$profile" 2>/dev/null) \
        || die "No source_profile found for profile $profile"

    resolve_base_creds "$base_profile"

    local creds creds_err
    creds_err=$(mktemp)
    creds=$(AWS_ACCESS_KEY_ID="$_BASE_AK" AWS_SECRET_ACCESS_KEY="$_BASE_SK" AWS_SESSION_TOKEN="$_BASE_ST" \
        aws sts assume-role --role-arn "$role_arn" --role-session-name "rrp-dev-$$" \
        --duration-seconds 3600 --output json 2>"$creds_err") \
        || { local err; err=$(<"$creds_err"); rm -f "$creds_err"; die "Failed to assume role $role_arn:\n$err"; }
    rm -f "$creds_err"
    _CRED_AK=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    _CRED_SK=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    _CRED_ST=$(echo "$creds" | jq -r '.Credentials.SessionToken')
}

# Build the CI container image if not already present or if ci/Containerfile has changed.
# A SHA-256 hash of ci/Containerfile is stored as an image label (containerfile.sha256).
# If the local Containerfile hash differs from the label, the image is rebuilt so that
# changes to the Containerfile (e.g. new tool versions, proxy CA handling) take effect
# without requiring manual `podman rmi`.
ensure_image() {
    [[ -n "$CONTAINER_ENGINE" ]] \
        || die "No container engine found. Install podman or docker."

    local containerfile_hash=""
    if [[ -f ci/Containerfile ]]; then
        containerfile_hash=$(sha256sum ci/Containerfile | awk '{print $1}')
    fi

    local needs_build=false
    if ! $CONTAINER_ENGINE image inspect "$CI_IMAGE" >/dev/null 2>&1; then
        needs_build=true
    elif [[ -n "$containerfile_hash" ]]; then
        local image_hash
        image_hash=$($CONTAINER_ENGINE image inspect "$CI_IMAGE" \
            --format '{{index .Labels "containerfile.sha256"}}' 2>/dev/null || true)
        if [[ "$image_hash" != "$containerfile_hash" ]]; then
            echo "Containerfile has changed (was: ${image_hash:-(none)}, now: ${containerfile_hash}). Rebuilding CI image..."
            needs_build=true
        fi
    fi

    if [[ "$needs_build" == "true" ]]; then
        echo "Building CI image..."
        local -a build_args=()
        # Auto-detect proxy CA cert from system trust store when PROXY_CA_CERT is not set.
        # This ensures the container can reach HTTPS endpoints through a TLS-intercepting proxy.
        local proxy_ca_cert="${PROXY_CA_CERT:-}"
        if [[ -z "$proxy_ca_cert" && -f /etc/pki/ca-trust/source/anchors/proxy-ca.crt ]]; then
            proxy_ca_cert="$(cat /etc/pki/ca-trust/source/anchors/proxy-ca.crt)"
        fi
        [[ -n "$proxy_ca_cert" ]] && build_args=("--build-arg" "PROXY_CA_CERT=${proxy_ca_cert}")
        local build_output
        if ! build_output=$($CONTAINER_ENGINE build \
            --label "containerfile.sha256=${containerfile_hash}" \
            -t "$CI_IMAGE" -f ci/Containerfile "${build_args[@]}" ci 2>&1); then
            echo "$build_output"
            die "Failed to build CI image."
        fi
    fi
}

# Load account IDs from a JSON file.
# Args: $1 = path to accounts.json, $2... = keys to extract
# Each key sets an uppercase variable: e.g. "rc" → RC_ACCOUNT
load_accounts() {
    local json_file="$1"
    shift

    [[ -f "$json_file" ]] || die "Account IDs file not found: $json_file"

    local key upper_key val
    for key in "$@"; do
        upper_key=$(echo "$key" | tr 'a-z' 'A-Z')
        val=$(jq -r ".$key" "$json_file") \
            || die "Failed to parse '$key' from $json_file"
        [[ "$val" != "null" ]] || die "Missing '$key' in $json_file"
        printf -v "${upper_key}_ACCOUNT" '%s' "$val"
    done
}

# Create temporary AWS config directory and set up EXIT trap.
# Sets: AWS_CONFIG_FILE, AWS_SHARED_CREDENTIALS_FILE, _aws_config_dir
# Caller should write profile heredoc to $AWS_CONFIG_FILE after calling this.
init_aws_config() {
    unset AWS_PROFILE AWS_DEFAULT_PROFILE

    _aws_config_dir=$(mktemp -d)
    export AWS_CONFIG_FILE="$_aws_config_dir/config"
    export AWS_SHARED_CREDENTIALS_FILE="$_aws_config_dir/credentials"
    touch "$AWS_SHARED_CREDENTIALS_FILE"

    trap 'rm -rf "${_aws_config_dir:-}" "${_CONTAINER_CONFIG:-}"' EXIT
}

# Build a container-safe AWS config file with resolved static credentials.
# credential_process won't work inside containers, so we resolve creds on the
# host and write them as static keys into a temp config file for mounting.
#
# Args: triplets of "host-profile container-profile region"
#   e.g.: write_container_config "rrp-ephemeral-rc rrp-rc us-east-1" "rrp-ephemeral-mc rrp-mc us-east-1"
#
# Sets: _CONTAINER_CONFIG, _CONTAINER_AWS_FLAGS
write_container_config() {
    _CONTAINER_CONFIG=$(mktemp)
    local first=true

    local spec host_profile container_profile region
    for spec in "$@"; do
        read -r host_profile container_profile region <<< "$spec"
        resolve_creds "$host_profile"

        [[ "$first" == "true" ]] || echo "" >> "$_CONTAINER_CONFIG"
        first=false

        cat >> "$_CONTAINER_CONFIG" <<EOF
[profile ${container_profile}]
aws_access_key_id = ${_CRED_AK}
aws_secret_access_key = ${_CRED_SK}
aws_session_token = ${_CRED_ST}
region = ${region}
EOF
    done

    _CONTAINER_AWS_FLAGS="-v ${_CONTAINER_CONFIG}:/tmp/aws-config:ro,z -e AWS_CONFIG_FILE=/tmp/aws-config -e AWS_SHARED_CREDENTIALS_FILE=/dev/null"
}

# Core ECS bastion task launch and readiness logic.
# Finds or launches a bastion ECS task, then waits for the exec agent.
#
# Args: $1 = cluster_id (e.g. "eph-abc-regional" or "regional")
# Sets: ecs_cluster, task_id (exported)
bastion_run_task() {
    local cluster_id="$1"
    export ecs_cluster="${cluster_id}-bastion"

    echo "==> Checking for running bastion tasks..."
    local existing_task
    existing_task=$(aws ecs list-tasks --cluster "$ecs_cluster" \
        --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null || true)

    if [[ -n "$existing_task" && "$existing_task" != "None" ]]; then
        export task_id=$(echo "$existing_task" | awk -F'/' '{print $NF}')
        echo "==> Found existing running task: $task_id"
    else
        echo "==> No running task found, starting a new one..."

        local task_def="${cluster_id}-bastion"
        local sg_id subnets vpc_id

        sg_id=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${cluster_id}-bastion" \
            --query 'SecurityGroups[0].GroupId' --output text) \
            || die "Could not find security group '${cluster_id}-bastion'."
        [[ "$sg_id" != "None" ]] \
            || die "Security group '${cluster_id}-bastion' not found."

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

        local run_output
        run_output=$(AWS_PAGER="" aws ecs run-task \
            --cluster "$ecs_cluster" \
            --task-definition "$task_def" \
            --launch-type FARGATE \
            --enable-execute-command \
            --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=DISABLED}") \
            || die "aws ecs run-task failed."

        local failures
        failures=$(echo "$run_output" | jq -r '.failures | length')
        [[ "$failures" == "0" ]] \
            || die "run-task returned failures: $(echo "$run_output" | jq -c '.failures')"

        export task_id=$(echo "$run_output" | jq -r '.tasks[0].taskArn' | awk -F'/' '{print $NF}')
    fi

    echo "==> Waiting for task to be running..."
    aws ecs wait tasks-running --cluster "$ecs_cluster" --tasks "$task_id"

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
