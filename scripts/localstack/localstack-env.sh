#!/usr/bin/env bash
#
# LocalStack environment CLI for ROSA HyperFleet.
#
# Manages a LocalStack-based local development environment that emulates the
# multi-account AWS infrastructure. Similar in spirit to ephemeral-env.sh but
# runs entirely on the developer's machine using Docker.
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

# Detect container engine (prefer podman, fall back to docker)
CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"

# Compose command — prefer 'docker compose' (v2 plugin), fall back to
# 'docker-compose' (standalone), and support podman-compose.
detect_compose_cmd() {
    if command -v podman-compose >/dev/null 2>&1 && [[ "${CONTAINER_ENGINE}" == *podman* ]]; then
        echo "podman-compose"
    elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
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
    echo "  up          Start LocalStack services"
    echo "  provision   Bootstrap the local AWS environment (run init-aws.sh)"
    echo "  teardown    Stop and clean up LocalStack"
    echo "  status      Show LocalStack service status"
    echo "  reset       Full destroy and recreate"
    echo "  shell       Open interactive shell with AWS CLI against LocalStack"
    echo ""
    echo "Quick start:"
    echo "  $0 up          # Start LocalStack"
    echo "  $0 provision   # Bootstrap AWS resources"
    echo "  $0 shell       # Interactive AWS CLI shell"
    echo "  $0 teardown    # Clean up"
}

check_auth_token() {
    if [[ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]]; then
        echo "⚠️  WARNING: LOCALSTACK_AUTH_TOKEN is not set." >&2
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
        || die "No compose command found. Install docker compose, docker-compose, or podman-compose."
    [[ -f "${REPO_ROOT}/${COMPOSE_FILE}" ]] \
        || die "Compose file not found: ${REPO_ROOT}/${COMPOSE_FILE}"
    check_auth_token \
        || die "LOCALSTACK_AUTH_TOKEN is required. See docs/localstack-testing.md for setup."
}

# Wait for LocalStack to become healthy
wait_for_localstack() {
    local max_wait=60
    local waited=0
    echo "Waiting for LocalStack to be ready..."
    while [ $waited -lt $max_wait ]; do
        if curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
            echo "  ✅ LocalStack is ready"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    die "LocalStack did not become ready within ${max_wait}s"
}

# =============================================================================
# Commands
# =============================================================================

cmd_up() {
    preflight
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
    echo "  ✅ LocalStack environment provisioned."
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

    echo "  ✅ LocalStack stopped and volumes removed."
}

cmd_status() {
    echo "LocalStack Status"
    echo "================="
    echo ""
    echo "  Endpoint: ${LOCALSTACK_ENDPOINT}"
    echo ""

    if ! curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
        echo "  Status: ❌ NOT RUNNING"
        echo ""
        echo "  Start with: make localstack-up"
        return 1
    fi

    echo "  Status: ✅ RUNNING"
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
        icon = '✅' if status in ('running', 'available') else '⚠️'
        print(f'    {icon} {svc}: {status}')
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
    echo "  ✅ LocalStack environment reset complete."
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

# =============================================================================
# Main
# =============================================================================

case "${1:-help}" in
    up)         cmd_up ;;
    provision)  cmd_provision ;;
    teardown)   cmd_teardown ;;
    status)     cmd_status ;;
    reset)      cmd_reset ;;
    shell)      cmd_shell ;;
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
