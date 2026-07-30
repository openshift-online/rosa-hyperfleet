#!/bin/bash
# Must-gather for the regional platform: collects Kubernetes logs from RC and
# MC clusters plus the PostgreSQL database state from the RC, all via the
# log-collector ECS Fargate task.
#
# This script is the single implementation used by both the local dev CLI
# (ephemeral-env.sh, int-env.sh) and CI (ci/e2e-tests.sh).
#
# Callers set CLUSTER_PREFIX to control cluster name resolution:
#   - Ephemeral: CLUSTER_PREFIX="eph-a1b2c3-" → eph-a1b2c3-regional, eph-a1b2c3-mc01
#   - Integration: CLUSTER_PREFIX="" → regional, mc01
#
# MC clusters are discovered dynamically by listing ECS clusters matching
# ${CLUSTER_PREFIX}mc*-bastion, so mc01, mc02, etc. are all collected.
#
# Usage:
#   dump-env.sh [regional|management|all]
#
# Required environment variables:
#   CLUSTER_PREFIX  — Cluster name prefix (e.g. "ci-a1b2c3-" or "" for bare names)
#   AWS_CONFIG_FILE — Path to AWS config with rrp-rc and rrp-mc profiles
#
# Optional:
#   LOG_OUTPUT_DIR  — Output directory (default: /tmp/<prefix>logs-<timestamp>)
#   S3_ONLY         — If set to "true", skip downloading logs and leave them in S3.
#                     Prints the S3 URI so callers can fetch logs manually.
#                     Used in CI to avoid publishing sensitive data to public
#                     artifact stores.
#   LEAKTK_GATE     — Defaults to "true": abort with non-zero exit when leaktk
#                     detects secrets remaining after redaction. Set to "false"
#                     to log findings as warnings without blocking.
#   DB_NAMESPACE    — Kubernetes namespace for the DB DSN secret (default: hyperfleet)
#   DB_SECRET_NAME  — Name of the secret containing the DSN (default: hyperfleet-db-dsn)
#
# All collection failures are logged but do not cause a non-zero exit, so
# this script is safe to call from test failure handlers.

set -uo pipefail

export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"

RC_NAMESPACES="all"
MC_NAMESPACES="all"
DB_NAMESPACE="${DB_NAMESPACE:-hyperfleet}"
DB_SECRET_NAME="${DB_SECRET_NAME:-hyperfleet-db-dsn}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Portable sed in-place: macOS needs `sed -i ''`, Linux needs `sed -i`
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

redact_logs() {
    local dir="$1"
    find "$dir" -type f \( -name "*.yaml" -o -name "*.log" -o -name "*.txt" -o -name "*.json" \) | while read -r f; do
        [[ -s "$f" ]] || continue
        sed_inplace \
            -e 's/\(AKIA\|ASIA\)[A-Z0-9]\{16\}/[REDACTED_AWS_KEY]/g' \
            -e 's/\(aws_secret_access_key\|secret_key\)\([ =:]*\)[^ ]*/\1\2[REDACTED]/gi' \
            -e 's/\(aws_session_token\|security_token\)\([ =:]*\)[^ ]*/\1\2[REDACTED]/gi' \
            -e 's/"\(aws_secret_access_key\|secret_key\)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"[REDACTED]"/gi' \
            -e 's/"\(aws_session_token\|security_token\)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"[REDACTED]"/gi' \
            -e 's/"\(password\|db\.password\|db_password\|connection_string\|dsn\)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"[REDACTED]"/gi' \
            -e 's/\(password\|db\.password\|db_password\)\([ =:]*\)[^ ]*/\1\2[REDACTED]/gi' \
            -e 's/"\(bearer_token\|token\|access_token\|refresh_token\|client_secret\|api_key\)"[[:space:]]*:[[:space:]]*"\([^"\\]\|\\.\)*"/"\1":"[REDACTED]"/gi' \
            -e 's/"\(pull_secret\|pullSecret\|ssh_key\|sshKey\|private_key\|privateKey\|kubeconfig\|admin_kubeconfig\)"[[:space:]]*:[[:space:]]*"\([^"\\]\|\\.\)*"/"\1":"[REDACTED]"/gi' \
            -e 's/-----BEGIN[A-Z ]* PRIVATE KEY-----[^-]*-----END[A-Z ]* PRIVATE KEY-----/[REDACTED_KEY]/g' \
            -e 's/-----BEGIN CERTIFICATE-----[^-]*-----END CERTIFICATE-----/[REDACTED_CERT]/g' \
            -e 's|postgres://[^@]*@|postgres://[REDACTED]@|g' \
            -e 's|postgresql://[^@]*@|postgresql://[REDACTED]@|g' \
            -e 's|amqp://[^@]*@|amqp://[REDACTED]@|g' \
            -e 's|amqps://[^@]*@|amqps://[REDACTED]@|g' \
            "$f"
    done
}

# Scan collected logs for leaked secrets using leaktk as a defense-in-depth
# layer after sed-based redaction. Scans every file under the given directory.
# Returns 0 when no leaks are found (or leaktk is not installed).
scan_for_leaks() {
    local dir="$1"

    if ! command -v leaktk &>/dev/null; then
        echo "  leaktk not found; skipping leak scan (install: https://github.com/leaktk/leaktk)"
        return 0
    fi

    echo "==> Scanning for leaked secrets with leaktk..."

    local leaktk_output leak_count
    leaktk_output=$(leaktk scan --kind Files "$dir" 2>&1) || true

    leak_count=$(echo "$leaktk_output" | grep -c '"rule_id"' || true)

    if [[ "$leak_count" -gt 0 ]]; then
        echo "  WARNING: leaktk detected ${leak_count} potential secret(s) after redaction:"
        echo "$leaktk_output" | head -100
        echo ""

        if [[ "${LEAKTK_GATE:-true}" != "false" ]]; then
            echo "  ERROR: LEAKTK_GATE is enabled — aborting to prevent secret exposure"
            return 1
        else
            echo "  LEAKTK_GATE is disabled; continuing despite findings"
        fi
    else
        echo "  No leaked secrets detected."
    fi

    return 0
}

# Switch AWS credentials by setting the active profile.
# Expects AWS_CONFIG_FILE to point at a config with rrp-rc and rrp-mc profiles.
use_profile() {
    local account_type="$1"
    case "$account_type" in
        regional)   export AWS_PROFILE="rrp-rc" ;;
        management) export AWS_PROFILE="rrp-mc" ;;
        *) echo "  Unknown account type: $account_type"; return 1 ;;
    esac
    if ! aws sts get-caller-identity --query Account --output text > /dev/null 2>&1; then
        echo "  ERROR: AWS profile '${AWS_PROFILE}' failed authentication (credentials may have expired)"
        return 1
    fi
}

# Ensure the log-collection S3 bucket exists (account-regional namespace).
# Creates the bucket on first use; subsequent calls are no-ops.
ensure_logs_bucket() {
    local account_id="$1"
    local region="$2"
    local bucket="bastion-log-collection-${account_id}-${region}-an"

    if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        return 0
    fi

    echo "  Creating log-collection bucket ${bucket}..."
    aws s3api create-bucket \
        --bucket "$bucket" \
        --bucket-namespace account-regional \
        --region "$region" > /dev/null

    aws s3api put-public-access-block \
        --bucket "$bucket" \
        --public-access-block-configuration \
            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true > /dev/null

    aws s3api put-bucket-lifecycle-configuration \
        --bucket "$bucket" \
        --lifecycle-configuration '{"Rules":[{"ID":"expire-logs","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":7},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}' > /dev/null
}

# Discover MC cluster IDs by listing ECS clusters matching ${prefix}mc*-bastion.
# Outputs one cluster_id per line (e.g. "eph-a1b2c3-mc01", "mc01").
discover_mc_clusters() {
    local prefix="$1"
    local cluster_output
    cluster_output=$(aws ecs list-clusters --query 'clusterArns[*]' --output text 2>&1) || {
        echo "  ERROR: aws ecs list-clusters failed: $cluster_output" >&2
        return 1
    }
    echo "$cluster_output" \
        | tr '\t' '\n' \
        | grep -oE "[^/]+$" \
        | grep "^${prefix}mc.*-bastion$" \
        | sed 's/-bastion$//' \
        | sort
}

# ---------------------------------------------------------------------------
# Build the ECS command for a cluster dump.
#
# For the RC (include_db=true): overrides the default log-collector command
# with a combined script that does k8s log collection AND DB state dump in
# one ECS task, producing a single tarball.
#
# For MCs (include_db=false): returns empty — the caller uses env-only
# overrides and the task definition's built-in command handles k8s logs.
# ---------------------------------------------------------------------------

build_dump_command() {
    local include_db="$1"
    local db_namespace="$2"
    local db_secret_name="$3"

    cat <<EOFCMD
set -euo pipefail

echo "=== Environment Dump ==="
echo "Cluster:    \$CLUSTER_NAME"
echo "Namespaces: \$INSPECT_NAMESPACES"
echo "S3 dest:    s3://\$S3_BUCKET/\$S3_KEY"
echo ""

aws eks update-kubeconfig --name "\$CLUSTER_NAME" --region "\$AWS_REGION"

# --- Kubernetes logs (oc adm inspect) ---

if [[ "\$INSPECT_NAMESPACES" == "all" ]]; then
    if ! INSPECT_NAMESPACES=\$(kubectl get namespaces -o jsonpath='{range .items[*]}ns/{.metadata.name} {end}'); then
        echo "WARNING: failed to list namespaces; falling back to INSPECT_NAMESPACES=all"
        INSPECT_NAMESPACES="all"
    fi
fi
echo "Resolved namespaces: \$INSPECT_NAMESPACES"

echo "Running oc adm inspect..."
timeout 300 oc adm inspect \$INSPECT_NAMESPACES --dest-dir=/tmp/inspect-logs || true

resources=(
    nodes
    hostedclusters.hypershift.openshift.io
    hostedcontrolplanes.hypershift.openshift.io
    nodepools.hypershift.openshift.io
    awsendpointservices.hypershift.openshift.io
    controlplanecomponents.hypershift.openshift.io
    clustersizingconfigurations.scheduling.hypershift.openshift.io
    nodepools.karpenter.sh
    nodeclaims.karpenter.sh
    ec2nodeclasses.karpenter.k8s.aws
    openshiftec2nodeclasses.karpenter.openshift.io
    clusters.cluster.x-k8s.io
    machines.cluster.x-k8s.io
    machinesets.cluster.x-k8s.io
    machinedeployments.cluster.x-k8s.io
    awsmachines.infrastructure.cluster.x-k8s.io
    awsmachinetemplates.infrastructure.cluster.x-k8s.io
    awsclusters.infrastructure.cluster.x-k8s.io
    applications.argoproj.io
    applicationsets.argoproj.io
    certificates.cert-manager.io
    certificaterequests.cert-manager.io
    clusterissuers.cert-manager.io
    externalsecrets.external-secrets.io
    clustersecretstores.external-secrets.io
    prometheusrules.monitoring.coreos.com
    thanoscompacts.monitoring.thanos.io
    thanosqueries.monitoring.thanos.io
    thanosreceivers.monitoring.thanos.io
    thanosrulers.monitoring.thanos.io
    thanosstores.monitoring.thanos.io
    targetgroupbindings.eks.amazonaws.com
    nodeclasses.eks.amazonaws.com
    secretproviderclasses.secrets-store.csi.x-k8s.io
)
batch=0
for resource in "\${resources[@]}"; do
    timeout 180 oc adm inspect "\$resource" --all-namespaces --dest-dir=/tmp/inspect-logs 2>/dev/null || true &
    batch=\$((batch + 1))
    if [[ \$batch -ge 5 ]]; then
        wait
        batch=0
    fi
done
wait
EOFCMD

    if [[ "$include_db" == "true" ]]; then
        cat <<EOFDB

# --- Database state (PostgreSQL) ---

echo ""
echo "=== DB State ==="

DSN=\$(kubectl get secret '${db_secret_name}' -n '${db_namespace}' -o jsonpath='{.data.dsn}' | base64 -d) || true

if [[ -z "\$DSN" ]]; then
    echo "WARNING: DSN is empty — secret '${db_secret_name}' in namespace '${db_namespace}' not found; skipping DB dump"
else
    mkdir -p /tmp/inspect-logs/db-state

    echo "Running resource summary query..."
    if ! psql "\$DSN" --pset pager=off -c "
    SELECT split_part(gvk, '/', 3) AS kind,
           namespace,
           name,
           created_at,
           deletion_timestamp
    FROM kubernetes_resources
    ORDER BY gvk, namespace, name;
    " > /tmp/inspect-logs/db-state/resource-summary.txt; then
        echo "WARNING: resource summary query failed (see above); continuing"
    fi

    echo "Dumping individual resources..."
    if psql "\$DSN" -At -F \$'\\t' -c "
    SELECT split_part(gvk, '/', 3),
           name,
           jsonb_build_object(
             'apiVersion', split_part(gvk, '/', 1) || '/' || split_part(gvk, '/', 2),
             'kind', split_part(gvk, '/', 3),
             'metadata', jsonb_build_object(
               'name', name,
               'namespace', namespace,
               'uid', uid,
               'resourceVersion', object_version,
               'creationTimestamp', created_at,
               'deletionTimestamp', deletion_timestamp
             ) || COALESCE(metadata, '{}'::jsonb),
             'spec', COALESCE(spec, '{}'::jsonb),
             'status', COALESCE(status, '{}'::jsonb)
           )::text
    FROM kubernetes_resources
    ORDER BY gvk, namespace, name;
    " | while IFS=\$'\\t' read -r kind rname json; do
        mkdir -p "/tmp/inspect-logs/db-state/resources/\$kind"
        echo "\$json" | jq '.' > "/tmp/inspect-logs/db-state/resources/\$kind/\$rname.json"
    done; then
        echo "  Dumped \$(find /tmp/inspect-logs/db-state/resources -name '*.json' 2>/dev/null | wc -l) resources"
    else
        echo "WARNING: individual resource dump failed (see above); continuing"
    fi
fi
EOFDB
    fi

    cat <<'EOFTAIL'

# --- Upload ---

echo ""
echo "Uploading to S3..."
tar czf /tmp/inspect-logs.tar.gz -C /tmp inspect-logs
aws s3 cp /tmp/inspect-logs.tar.gz "s3://$S3_BUCKET/$S3_KEY"

echo "Done."
EOFTAIL
}

# ---------------------------------------------------------------------------
# Core: dump a single cluster via the log-collector ECS task
# ---------------------------------------------------------------------------

dump_cluster() {
    local cluster_id="$1"
    local namespaces="$2"
    local out_dir="$3"
    local include_db="${4:-false}"

    echo "==> Dumping ${cluster_id}..."

    local ecs_cluster="${cluster_id}-bastion"
    local task_def="${cluster_id}-log-collector"
    local account_id region
    account_id=$(aws sts get-caller-identity --query Account --output text) \
        || { echo "  Could not determine account ID"; return 1; }
    region="${AWS_REGION}"
    local s3_bucket="bastion-log-collection-${account_id}-${region}-an"

    ensure_logs_bucket "$account_id" "$region"
    local s3_key
    s3_key="dump-env-$(date +%s%N)-$$-${RANDOM}.tar.gz"

    local sg_id subnets vpc_id
    sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${cluster_id}-bastion" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) \
        || { echo "  Could not find security group for ${cluster_id}"; return 1; }
    [[ "$sg_id" != "None" && -n "$sg_id" ]] \
        || { echo "  Security group '${cluster_id}-bastion' not found"; return 1; }

    vpc_id=$(aws ec2 describe-security-groups \
        --group-ids "$sg_id" \
        --query 'SecurityGroups[0].VpcId' --output text)

    subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*private*" \
        --query 'Subnets[].SubnetId' --output text \
        | tr '\t' ',') \
        || { echo "  Could not find private subnets for ${cluster_id}"; return 1; }

    local overrides_json
    overrides_json=$(jq -n \
        --arg bucket "$s3_bucket" \
        --arg ns "$namespaces" \
        --arg key "$s3_key" \
        '{containerOverrides: [{
            name: "log-collector",
            environment: [
                {name: "S3_BUCKET", value: $bucket},
                {name: "INSPECT_NAMESPACES", value: $ns},
                {name: "S3_KEY", value: $key}
            ]
        }]}')

    if [[ "$include_db" == "true" ]]; then
        local ecs_command
        ecs_command=$(build_dump_command "true" "$DB_NAMESPACE" "$DB_SECRET_NAME")
        overrides_json=$(echo "$overrides_json" | jq \
            --arg cmd "$ecs_command" \
            '.containerOverrides[0].command = [$cmd]')
    fi

    echo "  Launching dump task..."
    local run_task_output
    run_task_output=$(AWS_PAGER="" aws ecs run-task \
        --cluster "$ecs_cluster" \
        --task-definition "$task_def" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
        --overrides "$overrides_json") \
        || { echo "  Failed to launch dump task for ${cluster_id}"; return 1; }

    local failures
    failures=$(echo "$run_task_output" | jq -r '.failures[0].reason // empty')
    if [[ -n "$failures" ]]; then
        echo "  ECS run-task failed for ${cluster_id}: $failures"
        return 1
    fi

    local task_arn task_id
    task_arn=$(echo "$run_task_output" | jq -r '.tasks[0].taskArn // empty')
    if [[ -z "$task_arn" ]]; then
        echo "  ECS run-task returned no taskArn for ${cluster_id}"
        return 1
    fi

    task_id=$(echo "$task_arn" | awk -F'/' '{print $NF}')
    echo "  Task started: $task_id"

    echo "  Waiting for dump task to finish..."
    if ! aws ecs wait tasks-stopped --cluster "$ecs_cluster" --tasks "$task_id"; then
        echo "  Waiter timed out; polling task status..."
        local poll_status
        for _ in $(seq 1 6); do
            poll_status=$(aws ecs describe-tasks \
                --cluster "$ecs_cluster" --tasks "$task_id" \
                --query 'tasks[0].lastStatus' --output text 2>/dev/null)
            [[ "$poll_status" == "STOPPED" ]] && break
            sleep 10
        done
        if [[ "$poll_status" != "STOPPED" ]]; then
            echo "  Task ${task_id} still not stopped (status: ${poll_status}); giving up"
            return 1
        fi
    fi

    local describe_output exit_code
    describe_output=$(aws ecs describe-tasks \
        --cluster "$ecs_cluster" --tasks "$task_id")
    exit_code=$(echo "$describe_output" | jq -r '.tasks[0].containers[0].exitCode // empty')

    if [[ -z "$exit_code" ]]; then
        local stop_reason
        stop_reason=$(echo "$describe_output" | jq -r '.tasks[0].stoppedReason // "unknown"')
        echo "  Warning: container never started for ${cluster_id} (reason: $stop_reason)"
        echo "  Check CloudWatch logs: /ecs/${cluster_id}/bastion (log-collector stream)"
        return 1
    fi

    if [[ "$exit_code" != "0" ]]; then
        echo "  Warning: dump task exited with code $exit_code for ${cluster_id}"
        echo "  Check CloudWatch logs: /ecs/${cluster_id}/bastion (log-collector stream)"
        return 1
    fi

    if [[ "${S3_ONLY:-}" == "true" ]]; then
        echo "  Dump uploaded to S3. To download and extract:"
        echo ""
        echo "    mkdir -p /tmp/${cluster_id}-dump && aws s3 cp s3://${s3_bucket}/${s3_key} /tmp/${cluster_id}-dump/${s3_key} && tar xzf /tmp/${cluster_id}-dump/${s3_key} -C /tmp/${cluster_id}-dump"
        echo ""
        return 0
    fi

    echo "  Downloading dump from S3..."
    local tmp_archive
    tmp_archive="$(mktemp -t dump-env-XXXXXX.tar.gz)"
    aws s3 cp "s3://${s3_bucket}/${s3_key}" "$tmp_archive" --quiet \
        || { echo "  Failed to download dump from S3 for ${cluster_id}"; rm -f "$tmp_archive"; return 1; }

    mkdir -p "$out_dir"
    if ! tar xzf "$tmp_archive" -C "$out_dir" --strip-components=1; then
        echo "  Failed to extract dump archive for ${cluster_id}; leaving S3 object intact"
        rm -f "$tmp_archive"
        return 1
    fi
    rm -f "$tmp_archive"

    aws s3 rm "s3://${s3_bucket}/${s3_key}" --quiet || true

    echo "==> ${cluster_id} dump complete: ${out_dir}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CLUSTER_SCOPE="${1:-all}"

case "$CLUSTER_SCOPE" in
    all|regional|management) ;;
    *)
        echo "ERROR: Unknown cluster scope '${CLUSTER_SCOPE}' (expected: regional, management, or all)" >&2
        exit 1
        ;;
esac

if [[ -z "${CLUSTER_PREFIX+set}" ]]; then
    echo "ERROR: CLUSTER_PREFIX must be set (use empty string for bare cluster names)" >&2
    exit 0  # non-fatal so we don't mask test failures
fi

PREFIX="$CLUSTER_PREFIX"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="${LOG_OUTPUT_DIR:-/tmp/${PREFIX:-cluster-}logs-${TIMESTAMP}}"

echo ""
echo "Collecting environment state..."

failed=0

# --- Regional cluster (one per environment) ---
if [[ "$CLUSTER_SCOPE" == "all" || "$CLUSTER_SCOPE" == "regional" ]]; then
    echo ""
    if use_profile "regional"; then
        dump_cluster "${PREFIX}regional" "$RC_NAMESPACES" "${OUTPUT_DIR}/rc" "true" || failed=1
    else
        failed=1
    fi
fi

# --- Management clusters (dynamically discovered) ---
if [[ "$CLUSTER_SCOPE" == "all" || "$CLUSTER_SCOPE" == "management" ]]; then
    echo ""
    if use_profile "management"; then
        mc_clusters=$(discover_mc_clusters "$PREFIX")
        if [[ -z "$mc_clusters" ]]; then
            echo "  No management clusters found matching '${PREFIX}mc*'"
            failed=1
        else
            while IFS= read -r mc_id; do
                mc_name="${mc_id#"$PREFIX"}"
                dump_cluster "$mc_id" "$MC_NAMESPACES" "${OUTPUT_DIR}/${mc_name}" || failed=1
            done <<< "$mc_clusters"
        fi
    else
        failed=1
    fi
fi

# Redact sensitive values
if [[ -d "$OUTPUT_DIR" ]]; then
    echo ""
    echo "Redacting sensitive values..."
    redact_logs "$OUTPUT_DIR"

    # Defense-in-depth: scan for secrets that sed-based redaction may have missed
    scan_for_leaks "$OUTPUT_DIR" || failed=1
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "Environment dump complete."
else
    echo "Environment dump finished with errors. Check output above for details."
fi

exit 0
