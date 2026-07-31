#!/usr/bin/env bash
#
# LocalStack environment CLI for ROSA HyperFleet.
#
# Manages a LocalStack-based local development environment that emulates the
# multi-account AWS infrastructure. Similar in spirit to ephemeral-env.sh but
# runs entirely on the developer's machine using Podman (or Docker).
#
# Typically invoked via Makefile targets (make localstack-up, etc.)
# but can be run directly: ./scripts/localstack/localstack-env.sh up
#
# See docs/localstack-testing.md for full usage guide.

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

LOCALSTACK_ENDPOINT="http://localhost:4566"
COMPOSE_FILE="docker-compose.localstack.yaml"
CONTAINER_NAME="rosa-hyperfleet-localstack"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Activate podman socket if available (required for container-in-container
# support used by Lambda, ECS, and EKS emulation).
activate_podman_socket() {
    if command -v podman >/dev/null 2>&1; then
        systemctl --user enable --now podman.socket 2>/dev/null || true
    fi
}

# Compose command — use 'docker compose' (v2 plugin). Podman supports
# this natively via podman-docker compatibility.
detect_compose_cmd() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        echo ""
    fi
}

COMPOSE_CMD="$(detect_compose_cmd)"

# =============================================================================
# Helpers
# =============================================================================

die() { echo "Error: $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  up                Start LocalStack services"
    echo "  provision         Bootstrap the local AWS environment (run init-aws.sh)"
    echo "  teardown          Stop and clean up LocalStack"
    echo "  status            Show LocalStack service status"
    echo "  reset             Full destroy and recreate"
    echo "  shell             Open interactive shell with AWS CLI against LocalStack"
    echo "  assume-role       Assume an IAM role for a specific account (ACCOUNT=<name>)"
    echo "  eks-kubeconfig    Update kubeconfig for a LocalStack EKS cluster (CLUSTER=<name>)"
    echo "  trigger-pipeline  Trigger a CodeBuild/CodePipeline execution (PIPELINE=<name>)"
    echo ""
    echo "Quick start:"
    echo "  $0 up          # Start LocalStack"
    echo "  $0 provision   # Bootstrap AWS resources"
    echo "  $0 shell       # Interactive AWS CLI shell"
    echo "  $0 teardown    # Clean up"
}

check_auth_token() {
    if [[ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]]; then
        echo "WARNING: LOCALSTACK_AUTH_TOKEN is not set." >&2
        echo "   LocalStack Pro requires an auth token for EKS emulation," >&2
        echo "   Lambda container support, and IAM enforcement." >&2
        echo "" >&2
        echo "   Set it with:" >&2
        echo "     export LOCALSTACK_AUTH_TOKEN=<your-token>" >&2
        echo "" >&2
        echo "   Get a token at: https://app.localstack.cloud/account/apikeys" >&2
        echo "" >&2
        return 1
    fi
}

preflight() {
    [[ -n "${COMPOSE_CMD}" ]] \
        || die "No compose command found. Install podman (with docker compose support) or Docker."
    [[ -f "${REPO_ROOT}/${COMPOSE_FILE}" ]] \
        || die "Compose file not found: ${REPO_ROOT}/${COMPOSE_FILE}"
    check_auth_token \
        || die "LOCALSTACK_AUTH_TOKEN is required. See docs/localstack-testing.md for setup."
}

# Wait for LocalStack to become healthy (timeout 120s)
wait_for_localstack() {
    echo "Waiting for LocalStack to be ready..."
    if ! timeout 120 bash -c "
        until curl -sf ${LOCALSTACK_ENDPOINT}/_localstack/health > /dev/null 2>&1; do
            sleep 2
        done
    "; then
        die "LocalStack did not become ready within 120s"
    fi
    echo "  LocalStack is ready"
}

# =============================================================================
# Commands
# =============================================================================

cmd_up() {
    preflight
    activate_podman_socket
    echo "Starting LocalStack..."
    echo "  Compose file: ${COMPOSE_FILE}"
    echo "  Endpoint:     ${LOCALSTACK_ENDPOINT}"
    echo ""

    cd "${REPO_ROOT}"
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d

    wait_for_localstack

    echo ""
    echo "LocalStack is running."
    echo "  Endpoint: ${LOCALSTACK_ENDPOINT}"
    echo "  Use 'make localstack-provision' to bootstrap the AWS environment."
}

cmd_provision() {
    # Ensure LocalStack is running
    if ! curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
        echo "LocalStack is not running. Starting it first..."
        cmd_up
    fi

    echo ""
    echo "Bootstrapping LocalStack AWS environment..."

    # The init script is mounted at /etc/localstack/init/ready.d/ and runs
    # automatically on first start. For subsequent runs, execute it manually.
    if command -v docker >/dev/null 2>&1; then
        docker exec "${CONTAINER_NAME}" /etc/localstack/init/ready.d/init-aws.sh
    elif command -v podman >/dev/null 2>&1; then
        podman exec "${CONTAINER_NAME}" /etc/localstack/init/ready.d/init-aws.sh
    else
        die "No container engine found to exec into LocalStack."
    fi

    echo ""
    echo "  LocalStack environment provisioned."
    echo ""
    echo "  Next steps:"
    echo "    make localstack-shell   # Interactive AWS CLI shell"
    echo "    make localstack-status  # Check service health"
}

cmd_teardown() {
    preflight
    echo "Tearing down LocalStack..."

    cd "${REPO_ROOT}"
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" down -v

    echo "  LocalStack stopped and volumes removed."
}

cmd_status() {
    echo "LocalStack Status"
    echo "================="
    echo ""
    echo "  Endpoint: ${LOCALSTACK_ENDPOINT}"
    echo ""

    if ! curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
        echo "  Status: NOT RUNNING"
        echo ""
        echo "  Start with: make localstack-up"
        return 1
    fi

    echo "  Status: RUNNING"
    echo ""

    # Fetch and display service health
    local health
    health=$(curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" 2>/dev/null || echo "{}")

    echo "  Services:"
    echo "${health}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    services = data.get('services', {})
    for svc, status in sorted(services.items()):
        icon = 'OK' if status in ('running', 'available') else 'WARN'
        print(f'    [{icon}] {svc}: {status}')
except (json.JSONDecodeError, KeyError):
    print('    (could not parse health response)')
" 2>/dev/null || echo "    (python3 not available for health parsing)"

    echo ""
}

cmd_reset() {
    echo "Resetting LocalStack environment..."
    echo ""

    # Teardown (ignore errors if not running)
    cd "${REPO_ROOT}"
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" down -v 2>/dev/null || true

    # Remove persisted state
    rm -rf "${REPO_ROOT}/.localstack"

    echo "  Old state removed."
    echo ""

    # Bring up fresh
    cmd_up

    echo ""
    echo "  LocalStack environment reset complete."
}

cmd_shell() {
    # Check LocalStack is running
    if ! curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
        die "LocalStack is not running. Start with: make localstack-up"
    fi

    echo ""
    echo "ROSA HyperFleet LocalStack Shell"
    echo ""
    echo "  Endpoint: ${LOCALSTACK_ENDPOINT}"
    echo "  Region:   us-east-1"
    echo ""
    echo "  All AWS CLI commands are pre-configured to use LocalStack."
    echo "  Example: aws s3 ls"
    echo "  Example: aws ssm get-parameter --name /infra/localstack/us-east-1/account_id"
    echo ""
    echo "  Type 'exit' to leave."
    echo ""

    # Launch a shell with AWS environment configured for LocalStack
    AWS_ENDPOINT_URL="${LOCALSTACK_ENDPOINT}" \
    AWS_ACCESS_KEY_ID="test" \
    AWS_SECRET_ACCESS_KEY="test" \
    AWS_DEFAULT_REGION="us-east-1" \
    AWS_REGION="us-east-1" \
    PS1="(localstack) \w \$ " \
        bash --norc --noprofile
}

cmd_assume_role() {
    local account_name="${ACCOUNT:-}"
    if [[ -z "${account_name}" ]]; then
        die "ACCOUNT is required. Usage: make localstack-assume-role ACCOUNT=<central|rc|mc|customer>"
    fi

    # Map account name to account ID
    local account_id=""
    case "${account_name}" in
        central)  account_id="000000000001" ;;
        rc)       account_id="000000000002" ;;
        mc)       account_id="000000000003" ;;
        customer) account_id="000000000004" ;;
        *)
            die "Unknown account: ${account_name}. Must be one of: central, rc, mc, customer"
            ;;
    esac

    # Check LocalStack is running
    if ! curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
        die "LocalStack is not running. Start with: make localstack-up"
    fi

    if ! command -v awslocal >/dev/null 2>&1; then
        die "awslocal not found. Install with: pip install awscli-local"
    fi

    local role_arn="arn:aws:iam::${account_id}:role/OrganizationAccountAccessRole"
    local session_name="localstack-${account_name}"

    echo ""
    echo "Assuming role for account: ${account_name} (${account_id})"
    echo "  Role ARN: ${role_arn}"
    echo ""

    # Call STS assume-role
    local creds
    creds=$(AWS_PAGER="" awslocal sts assume-role \
        --role-arn "${role_arn}" \
        --role-session-name "${session_name}" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text) || die "Failed to assume role: ${role_arn}"

    local access_key secret_key session_token
    access_key=$(echo "${creds}" | awk '{print $1}')
    secret_key=$(echo "${creds}" | awk '{print $2}')
    session_token=$(echo "${creds}" | awk '{print $3}')

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  LocalStack — ${account_name} account (${account_id})             ║"
    echo "║  Role: OrganizationAccountAccessRole                    ║"
    echo "║  Type 'exit' to return to your normal shell.            ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # Launch a subshell with the assumed-role credentials
    AWS_ACCESS_KEY_ID="${access_key}" \
    AWS_SECRET_ACCESS_KEY="${secret_key}" \
    AWS_SESSION_TOKEN="${session_token}" \
    AWS_ENDPOINT_URL="${LOCALSTACK_ENDPOINT}" \
    AWS_DEFAULT_REGION="us-east-1" \
    AWS_REGION="us-east-1" \
    PS1="(localstack:${account_name}) \w \$ " \
        bash --norc --noprofile
}

cmd_eks_kubeconfig() {
    local cluster_name="${CLUSTER:-rc-cluster}"

    # Check LocalStack is running
    if ! curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
        die "LocalStack is not running. Start with: make localstack-up"
    fi

    if ! command -v awslocal >/dev/null 2>&1; then
        die "awslocal not found. Install with: pip install awscli-local"
    fi

    echo ""
    echo "Updating kubeconfig for EKS cluster: ${cluster_name}"
    echo ""

    AWS_PAGER="" awslocal eks update-kubeconfig --name "${cluster_name}" \
        || die "Failed to update kubeconfig for cluster: ${cluster_name}"

    echo ""
    echo "Kubeconfig updated for cluster: ${cluster_name}"
    echo ""
    echo "  You can now use kubectl to interact with the cluster:"
    echo "    kubectl get nodes"
    echo "    kubectl get namespaces"
    echo "    kubectl cluster-info"
    echo ""
    echo "  Note: LocalStack Pro uses k3s to emulate EKS. The cluster"
    echo "  runs inside the LocalStack container."
    echo ""
}

cmd_trigger_pipeline() {
    local pipeline_name="${PIPELINE:-}"
    if [[ -z "${pipeline_name}" ]]; then
        die "PIPELINE is required. Usage: make localstack-trigger-pipeline PIPELINE=<name>"
    fi

    # Check LocalStack is running
    if ! curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
        die "LocalStack is not running. Start with: make localstack-up"
    fi

    if ! command -v awslocal >/dev/null 2>&1; then
        die "awslocal not found. Install with: pip install awscli-local"
    fi

    local source_repo="${REPO:-}"
    local source_commit="${COMMIT:-}"

    # Determine source directory for CodeBuild
    local source_dir=""
    if [[ -n "${source_repo}" ]]; then
        source_dir=$(mktemp -d)
        echo "Cloning ${source_repo}..."
        if [[ -n "${source_commit}" ]]; then
            git clone --quiet "${source_repo}" "${source_dir}/repo" \
                || die "Failed to clone ${source_repo}"
            git -C "${source_dir}/repo" checkout --quiet "${source_commit}" \
                || die "Failed to checkout ${source_commit}"
        else
            git clone --quiet --depth 1 "${source_repo}" "${source_dir}/repo" \
                || die "Failed to clone ${source_repo}"
        fi
        source_dir="${source_dir}/repo"
    else
        source_dir="${REPO_ROOT}"
    fi

    # Check if this is a CodeBuild project or CodePipeline
    local is_codebuild=false
    local is_codepipeline=false

    if AWS_PAGER="" awslocal codebuild batch-get-projects --names "${pipeline_name}" \
        --query 'projects[0].name' --output text 2>/dev/null | grep -qv "^None$"; then
        is_codebuild=true
    fi

    if AWS_PAGER="" awslocal codepipeline get-pipeline --name "${pipeline_name}" \
        >/dev/null 2>&1; then
        is_codepipeline=true
    fi

    if [[ "${is_codebuild}" == "true" ]]; then
        echo ""
        echo "Triggering CodeBuild project: ${pipeline_name}"
        echo ""

        # Upload source to S3
        local source_bucket="terraform-state-000000000001"
        local source_key="codebuild-source/${pipeline_name}/source.zip"

        echo "  Packaging source from: ${source_dir}"
        local zip_file
        zip_file=$(mktemp /tmp/source-XXXXXX.zip)
        (cd "${source_dir}" && zip -r -q "${zip_file}" . -x '.git/*') \
            || die "Failed to create source archive"

        echo "  Uploading to s3://${source_bucket}/${source_key}"
        AWS_PAGER="" awslocal s3 cp "${zip_file}" "s3://${source_bucket}/${source_key}" \
            || die "Failed to upload source to S3"
        rm -f "${zip_file}"

        # Start the build
        local build_id
        build_id=$(AWS_PAGER="" awslocal codebuild start-build \
            --project-name "${pipeline_name}" \
            --source-type-override "S3" \
            --source-location-override "${source_bucket}/${source_key}" \
            --query 'build.id' --output text) \
            || die "Failed to start build"

        echo ""
        echo "  Build started: ${build_id}"
        echo ""
        echo "  Check status:"
        echo "    awslocal codebuild batch-get-builds --ids ${build_id} --query 'builds[0].buildStatus'"
        echo ""
        echo "  Tail logs:"
        echo "    awslocal logs tail /aws/codebuild/${pipeline_name} --follow"
        echo ""

    elif [[ "${is_codepipeline}" == "true" ]]; then
        echo ""
        echo "Triggering CodePipeline: ${pipeline_name}"
        echo ""

        local execution_id
        execution_id=$(AWS_PAGER="" awslocal codepipeline start-pipeline-execution \
            --name "${pipeline_name}" \
            --query 'pipelineExecutionId' --output text) \
            || die "Failed to start pipeline execution"

        echo "  Execution started: ${execution_id}"
        echo ""
        echo "  Check status:"
        echo "    awslocal codepipeline get-pipeline-execution --pipeline-name ${pipeline_name} --pipeline-execution-id ${execution_id}"
        echo ""
        echo "  List executions:"
        echo "    awslocal codepipeline list-pipeline-executions --pipeline-name ${pipeline_name}"
        echo ""
    else
        die "No CodeBuild project or CodePipeline found with name: ${pipeline_name}"
    fi

    # Clean up temporary clone directory
    if [[ -n "${source_repo}" && -n "${source_dir}" ]]; then
        rm -rf "$(dirname "${source_dir}")"
    fi
}

# =============================================================================
# Main
# =============================================================================

case "${1:-help}" in
    up)                cmd_up ;;
    provision)         cmd_provision ;;
    teardown)          cmd_teardown ;;
    status)            cmd_status ;;
    reset)             cmd_reset ;;
    shell)             cmd_shell ;;
    assume-role)       cmd_assume_role ;;
    eks-kubeconfig)    cmd_eks_kubeconfig ;;
    trigger-pipeline)  cmd_trigger_pipeline ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        echo ""
        usage
        exit 1
        ;;
esac
