#!/usr/bin/env bash
# Run e2e API tests from rosa-hyperfleet-api against the provisioned environment.
#
# API URL resolution (first match wins):
#   1. BASE_URL env var            — set by local wrapper scripts (ephemeral-env.sh, int-env.sh)
#   2. CREDS_DIR/api_url file — Prow-mounted secret for the standing int environment
#   3. SHARED_DIR terraform output — written by ephemeral-provider during CI provisioning
#
# Parallel execution (enabled by default):
#   Phase 1 (parallel): Platform API + ZOA tests
#   Phase 2 (parallel, gated): HCP + ROSA CLI + Monitoring (only if Phase 1 passes)
#   Set E2E_PARALLEL=false to run sequentially (legacy mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

source "${SCRIPT_DIR}/setup-aws-profiles.sh"

if [[ -n "${BASE_URL:-}" ]]; then
  echo "Using BASE_URL from environment: ${BASE_URL}"
else
  if [[ -r "${CREDS_DIR}/api_url" ]]; then
    echo "Using API URL from ${CREDS_DIR}/api_url (CI pre-existing environment)"
    BASE_URL="$(cat "${CREDS_DIR}/api_url")"
  else
    echo "No ${CREDS_DIR}/api_url found, falling back to terraform outputs (ephemeral environment)"
    TF_OUTPUTS="${SHARED_DIR}/regional-terraform-outputs.json"
    if [[ ! -r "${TF_OUTPUTS}" ]]; then
      echo "ERROR: ${TF_OUTPUTS} does not exist or is not readable" >&2
      exit 1
    fi
    BASE_URL="$(jq -r '.api_gateway_invoke_url.value // empty' "${TF_OUTPUTS}")"
    if [[ -z "${BASE_URL}" ]]; then
      echo "ERROR: api_gateway_invoke_url.value not found in ${TF_OUTPUTS}" >&2
      exit 1
    fi
  fi
fi
export BASE_URL
export HYPERFLEET_URL="${BASE_URL}"
echo "Running API e2e tests against ${BASE_URL}"

# RHOBS API URL for observability E2E tests (Thanos Query read path).
# The query path is always available — uses the same invoke URL as remote-write.
if [[ -z "${RHOBS_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/rhobs_api_url" ]]; then
    RHOBS_API_URL="$(cat "${CREDS_DIR}/rhobs_api_url")"
  elif [[ -n "${TF_OUTPUTS:-}" && -r "${TF_OUTPUTS:-}" ]]; then
    RHOBS_API_URL="$(jq -r '.rhobs_api_url.value // empty' "${TF_OUTPUTS}")"
  fi
fi
if [[ -n "${RHOBS_API_URL:-}" ]]; then
  export RHOBS_API_URL
  echo "RHOBS API URL: ${RHOBS_API_URL}"
else
  echo "WARNING: RHOBS_API_URL not available — observability tests will be skipped"
fi

# ZOA RC/MC API URLs, consumed further down by the rosa-hyperfleet-zoa clone
# that runs its own `Label("smoke")` specs (see that repo's test/e2e/). Same
# resolution order as RHOBS_API_URL above; local wrapper scripts
# (ephemeral-env.sh) already export these directly, so this is mainly for
# CI-triggered runs (Prow). ZOA_MC_API_URL is only absent if this environment
# genuinely has no MC (empty provision_mcs) — ephemeral envs provision one
# MC by default, so in the common case both resolve and both get tested.
if [[ -z "${ZOA_RC_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/zoa_rc_api_url" ]]; then
    ZOA_RC_API_URL="$(cat "${CREDS_DIR}/zoa_rc_api_url")"
  elif [[ -n "${TF_OUTPUTS:-}" && -r "${TF_OUTPUTS:-}" ]]; then
    ZOA_RC_API_URL="$(jq -r '.zoa_api_function_url.value // empty' "${TF_OUTPUTS}")"
  fi
fi
if [[ -z "${ZOA_MC_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/zoa_mc_api_url" ]]; then
    ZOA_MC_API_URL="$(cat "${CREDS_DIR}/zoa_mc_api_url")"
  elif [[ -n "${SHARED_DIR:-}" && -r "${SHARED_DIR}/management-terraform-outputs.json" ]]; then
    ZOA_MC_API_URL="$(jq -r '.zoa_api_function_url.value // empty' "${SHARED_DIR}/management-terraform-outputs.json")"
  fi
fi
if [[ -n "${ZOA_RC_API_URL:-}" ]]; then
  export ZOA_RC_API_URL
  echo "ZOA RC API URL: ${ZOA_RC_API_URL}"
else
  echo "ZOA_RC_API_URL not available — ZOA RC tests will target MC only (if available)"
fi
[[ -n "${ZOA_MC_API_URL:-}" ]] && export ZOA_MC_API_URL && echo "ZOA MC API URL: ${ZOA_MC_API_URL}"

# Use the regional account profile for authenticated API calls
export AWS_PROFILE="rrp-rc"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export PATH="/usr/local/sessionmanagerplugin/bin:/usr/bin:/usr/local/bin:${PATH}"

# Compute CLUSTER_PREFIX early so it's available for pre-cleanup hooks (log
# collection while HCPs still exist), not just in the post-test failure handler.
# Callers (e.g. ephemeral-env.sh) may set CLUSTER_PREFIX directly; honour it.
if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
    echo "Using caller-provided CLUSTER_PREFIX=${CLUSTER_PREFIX}"
elif [[ -r "${CREDS_DIR}/api_url" ]]; then
    export CLUSTER_PREFIX=""
elif [[ -n "${BUILD_ID:-}" ]]; then
    _hash="$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-6)" \
        || { echo "WARNING: sha256sum failed — CLUSTER_PREFIX not set"; _hash=""; }
    if [[ -n "$_hash" ]]; then
        export CLUSTER_PREFIX="eph-${_hash}-"
    fi
else
    echo "WARNING: no ${CREDS_DIR}/api_url and BUILD_ID not set — CLUSTER_PREFIX unset, log collection disabled" >&2
fi

E2E_REF="${E2E_REF:-main}"
E2E_REPO="${E2E_REPO:-https://github.com/openshift-online/rosa-hyperfleet-api.git}"
CLI_REF="${CLI_REF:-main}"
CLI_REPO="${CLI_REPO:-https://github.com/openshift-online/rosa-hyperfleet-cli.git}"
ROSA_REPO_URL="${ROSA_REPO_URL:-https://github.com/openshift/rosa}"
ROSA_REPO_BRANCH="${ROSA_REPO_BRANCH:-hyperfleet-v2}"
ROSA_LABEL_FILTER="${ROSA_LABEL_FILTER:-}"
ROSA_TEST_PROFILE="${ROSA_TEST_PROFILE:-rosa-hcp-basic}"
E2E_SKIP_PLATFORM_API="${E2E_SKIP_PLATFORM_API:-false}"  # Set to "true" to skip
E2E_SKIP_HCP="${E2E_SKIP_HCP:-false}"  # Set to "true" to skip
E2E_SKIP_MONITORING="${E2E_SKIP_MONITORING:-false}"  # Set to "true" to skip
E2E_SKIP_ROSA_CLI="${E2E_SKIP_ROSA_CLI:-true}"  # Set to "true" to skip
E2E_SKIP_ZOA="${E2E_SKIP_ZOA:-false}"  # Set to "true" to skip
ZOA_REF="${ZOA_REF:-main}"
ZOA_REPO="${ZOA_REPO:-https://github.com/openshift-online/rosa-hyperfleet-zoa.git}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ==============================================================================
# Parallel execution support (bash 3.2 compatible)
# ==============================================================================

E2E_PARALLEL="${E2E_PARALLEL:-true}"

# Color output for parallel execution
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# Job tracking (bash 3.2 compatible - no associative arrays)
PHASE1_PIDS=()
PHASE2_PIDS=()
PID_NAMES=""
PID_LOGS=""
PID_START_TIME=""

# Helper functions for job metadata
get_name_for_pid() {
  local target_pid="$1"
  echo "$PID_NAMES" | grep "^${target_pid}:" | cut -d: -f2
}

get_log_for_pid() {
  local target_pid="$1"
  echo "$PID_LOGS" | grep "^${target_pid}:" | cut -d: -f3
}

get_start_time_for_pid() {
  local target_pid="$1"
  echo "$PID_START_TIME" | grep "^${target_pid}:" | cut -d: -f2
}

# Run a command in background with logging
# Args: <phase> <job_name> <function_name>
run_background_test() {
  local phase="$1"
  local name="$2"
  local func="$3"
  local log_file="${WORK_DIR}/${name}.log"

  echo -e "${BLUE}▶${NC} Starting ${name}"
  echo "  Log: $log_file"

  # Run function in background with structured logging
  {
    echo "==================================================================="
    echo "Job: $name"
    echo "Started: $(date)"
    echo "==================================================================="
    echo ""

    local start_ts exit_code duration
    start_ts=$(date +%s)

    set +e
    $func
    exit_code=$?
    set -e

    duration=$(($(date +%s) - start_ts))

    echo ""
    echo "==================================================================="
    echo "Job: $name"
    if [[ $exit_code -eq 0 ]]; then
      echo "Status: SUCCESS"
    else
      echo "Status: FAILED (exit code: $exit_code)"
    fi
    echo "Duration: ${duration}s"
    echo "Finished: $(date)"
    echo "==================================================================="

    exit $exit_code
  } &> "$log_file" &

  local pid=$!

  # Track job metadata
  if [[ "$phase" == "1" ]]; then
    PHASE1_PIDS+=("$pid")
  else
    PHASE2_PIDS+=("$pid")
  fi

  PID_NAMES="${PID_NAMES}${pid}:${name}
"
  PID_LOGS="${PID_LOGS}${pid}:${name}:${log_file}
"
  PID_START_TIME="${PID_START_TIME}${pid}:$(date +%s)
"

  echo "  PID: $pid"
}

# Wait for a phase and return failure count
wait_phase_jobs() {
  local phase_name="$1"
  shift
  local pids=("$@")

  if [[ "${#pids[@]}" -eq 0 ]]; then
    return 0
  fi

  echo ""
  echo -e "${YELLOW}=== Waiting for ${phase_name} (${#pids[@]} jobs) ===${NC}"
  echo ""

  local failed=0
  local succeeded=0

  for pid in "${pids[@]}"; do
    local name log_file start_time
    name=$(get_name_for_pid "$pid")
    log_file=$(get_log_for_pid "$pid")
    start_time=$(get_start_time_for_pid "$pid")

    echo -n "Waiting for ${name} (PID: $pid)..."

    if wait "$pid"; then
      local elapsed=$(($(date +%s) - start_time))
      echo -e " ${GREEN}✓${NC} (${elapsed}s)"
      ((succeeded++))
    else
      local exit_code=$?
      local elapsed=$(($(date +%s) - start_time))
      echo -e " ${RED}✗${NC} (exit code: $exit_code, ${elapsed}s)"
      ((failed++))
    fi
  done

  echo ""
  echo -e "${phase_name} Results:"
  echo "  ${GREEN}Passed:${NC} $succeeded"
  echo "  ${RED}Failed:${NC} $failed"
  echo ""

  return $failed
}

# Display all test logs at the end
display_all_logs() {
  echo ""
  echo "==================================================================="
  echo "Test Suite Logs"
  echo "==================================================================="

  if [[ -z "$PID_LOGS" ]]; then
    echo "No logs available"
  else
    # Use process substitution to avoid subshell issues
    while IFS=: read -r pid name log_file; do
      if [[ -n "$log_file" && -f "$log_file" ]]; then
        echo ""
        echo "==================================================================="
        echo "Log: $name"
        echo "==================================================================="
        cat "$log_file"
        echo ""
      fi
    done < <(echo "$PID_LOGS")
  fi

  echo "==================================================================="
}

# ==============================================================================
# Test suite wrapper functions
# ==============================================================================

run_platform_api_tests() {
  echo ""
  echo "=== Platform API Tests ==="
  cd "${WORK_DIR}/api"
  make test-e2e-api
}

run_zoa_tests() {
  echo ""
  echo "=== ZOA Tests ==="

  if [[ -z "${ZOA_RC_API_URL:-}" ]] && [[ -z "${ZOA_MC_API_URL:-}" ]]; then
    echo "ERROR: neither ZOA_RC_API_URL nor ZOA_MC_API_URL resolved — ZOA e2e tests cannot run" >&2
    return 1
  fi

  if ! git clone --depth 1 --branch "${ZOA_REF}" "${ZOA_REPO}" "${WORK_DIR}/zoa"; then
    echo "WARNING: failed to clone zoa from ${ZOA_REPO}@${ZOA_REF} — ZOA e2e tests skipped" >&2
    return 1
  fi

  if [[ "${JOB_TYPE:-}" == "periodic" ]]; then
    echo "Nightly run — executing full ZOA e2e suite"
    make -C "${WORK_DIR}/zoa" test-e2e
  else
    make -C "${WORK_DIR}/zoa" test-e2e-smoke
  fi
}

run_hcp_creation_tests() {
  echo ""
  echo "=== HCP Creation Tests ==="

  local HCP_CLUSTER_NAME="e2e-$(date +%s)"
  local CLI_WORK_DIR
  CLI_WORK_DIR="$(mktemp -d)"

  # Ensure cleanup happens even on failure, and we're in a safe directory
  trap 'cd /tmp 2>/dev/null || true; rm -rf "${CLI_WORK_DIR}"' RETURN

  cd "${CLI_WORK_DIR}"

  git clone --depth 1 --branch "${CLI_REF}" \
    "${CLI_REPO}" "${CLI_WORK_DIR}/cli"
  cd "${CLI_WORK_DIR}/cli"

  export GOTOOLCHAIN=auto
  make build
  chmod 755 ./bin/rosactl

  export ROSACTL_BIN="${CLI_WORK_DIR}/cli/bin/rosactl"

  cd "${WORK_DIR}/api"

  "${ROSACTL_BIN}" login --url "${BASE_URL}"
  echo "Creating HCP cluster: ${HCP_CLUSTER_NAME}"

  # Collect cluster logs before HCP cleanup
  if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
    export PRE_CLEANUP_HOOK="S3_ONLY=true ${REPO_ROOT}/scripts/dev/dump-env.sh"
  fi

  export GINKGO_NO_COLOR=TRUE
  if [[ -n "${E2E_SKIP_CLEANUP:-}" ]]; then
    echo "E2E_SKIP_CLEANUP is set — cleanup specs will be skipped"
    export E2E_LABEL_FILTER='!cleanup'
  fi

  # Alertmanager tunnel for silence e2e specs
  if [[ "${E2E_SKIP_ALERTMANAGER_FORWARD:-}" != "true" ]]; then
    if [[ -z "${ALERTMANAGER_URL:-}" && -z "${E2E_ALERTMANAGER_URL:-}" && -n "${CLUSTER_PREFIX:-}" ]]; then
      echo "=== Alertmanager tunnel for silence e2e specs ==="
      if source "${REPO_ROOT}/ci/alertmanager-forward.sh" && start_alertmanager_forward; then
        echo "Silence e2e specs enabled (E2E_ALERTMANAGER_URL=${E2E_ALERTMANAGER_URL})"
      else
        echo "WARNING: Alertmanager tunnel failed — silence specs will skip" >&2
      fi
    fi
  fi

  make test-e2e-cli

  echo "HCP creation test completed for: ${HCP_CLUSTER_NAME}"
}

run_rosa_cli_tests() {
  echo ""
  echo "=== ROSA CLI Tests ==="

  cd "${WORK_DIR}/api"

  export ROSA_REPO_URL="${ROSA_REPO_URL}"
  export ROSA_REPO_BRANCH="${ROSA_REPO_BRANCH}"
  export TEST_PROFILE="${ROSA_TEST_PROFILE}"
  export GOTOOLCHAIN=auto

  ROSA_LABEL_FILTER="${ROSA_LABEL_FILTER}" make test-e2e-rosa-cli
}

run_monitoring_tests() {
  echo ""
  echo "=== Platform Monitoring Tests ==="

  cd "${WORK_DIR}/api"
  make test-e2e-platform-monitoring
}

# ---------------------------------------------------------------------------
# When triggered by a rosa-hyperfleet-zoa PR, only run ZOA's full e2e suite —
# API, HCP, and monitoring tests are irrelevant for ZOA code changes.
# ---------------------------------------------------------------------------
if [[ "${REPO_NAME:-}" == "rosa-hyperfleet-zoa" ]]; then
  echo ""
  echo "=== ZOA PR detected — running ZOA full e2e only ==="
  echo ""
  zoa_exit=0
  if [[ -n "${ZOA_RC_API_URL:-}" ]] || [[ -n "${ZOA_MC_API_URL:-}" ]]; then
    if git clone --depth 1 --branch "${ZOA_REF}" "${ZOA_REPO}" "${WORK_DIR}/zoa"; then
      make -C "${WORK_DIR}/zoa" test-e2e || zoa_exit=$?
    else
      echo "ERROR: failed to clone zoa from ${ZOA_REPO}@${ZOA_REF}" >&2
      zoa_exit=1
    fi
  else
    echo "ERROR: neither ZOA_RC_API_URL nor ZOA_MC_API_URL resolved — ZOA e2e tests cannot run" >&2
    zoa_exit=1
  fi
  echo ""
  echo "E2E results: zoa=$zoa_exit"
  exit $zoa_exit
fi

# ---------------------------------------------------------------------------
# Standard flow: API tests + ZOA tests + HCP + monitoring
# Supports both parallel (default) and sequential (E2E_PARALLEL=false) execution
# ---------------------------------------------------------------------------
echo ""
echo "=== Cloning API Repository ==="
echo "Repo: ${E2E_REPO} - Branch: ${E2E_REF}"
echo ""
git clone --depth 1 --branch "${E2E_REF}" \
  "${E2E_REPO}" "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

echo "working commit $(git rev-parse HEAD)"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

# Get regional account ID for CLI tests
if [[ -z "${E2E_ACCOUNT_ID:-}" ]]; then
  export E2E_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  echo "Regional account ID: ${E2E_ACCOUNT_ID}"
fi

# Check for customer credentials
_have_customer_creds=false
if aws configure export-credentials --profile rrp-customer --format process &>/dev/null; then
  export CUSTOMER_AWS_PROFILE="rrp-customer"
  echo "Customer profile rrp-customer is available"

  if [[ -z "${E2E_CUSTOMER_ACCOUNT_ID:-}" ]]; then
    export E2E_CUSTOMER_ACCOUNT_ID="$(aws sts get-caller-identity --profile rrp-customer --query Account --output text)"
    echo "Customer account ID: ${E2E_CUSTOMER_ACCOUNT_ID:0:8}..."
  fi
  _have_customer_creds=true
else
  echo "WARNING: No rrp-customer profile available — skipping HCP/ROSA CLI/Monitoring tests"
fi

# ==============================================================================
# Parallel Execution Mode (default)
# ==============================================================================

if [[ "${E2E_PARALLEL}" == "true" ]]; then
  echo ""
  echo "==================================================================="
  echo "Running E2E tests in PARALLEL mode"
  echo "==================================================================="

  parallel_start=$(date +%s)

  platform_rc=0
  hcp_rc=0
  monitoring_rc=0
  rosa_cli_rc=0
  zoa_exit=0

  # Phase 1: Independent tests (Platform API + ZOA)
  echo ""
  echo -e "${YELLOW}=== Phase 1: Independent Test Suites ===${NC}"
  echo ""

  phase1_start=$(date +%s)

  if [[ "${E2E_SKIP_PLATFORM_API}" == "true" ]]; then
    echo -e "${YELLOW}⊘${NC} Skipping Platform API tests (E2E_SKIP_PLATFORM_API=true)"
  else
    run_background_test 1 "platform-api" run_platform_api_tests
  fi

  if [[ "${E2E_SKIP_ZOA}" == "true" ]]; then
    echo -e "${YELLOW}⊘${NC} Skipping ZOA tests (E2E_SKIP_ZOA=true)"
  else
    run_background_test 1 "zoa" run_zoa_tests
  fi

  # Wait for Phase 1 completion
  phase1_failures=0
  if [[ "${#PHASE1_PIDS[@]}" -gt 0 ]]; then
    wait_phase_jobs "Phase 1" "${PHASE1_PIDS[@]}" || phase1_failures=$?

    # Extract individual exit codes from PIDs
    for pid in "${PHASE1_PIDS[@]}"; do
      _name=$(get_name_for_pid "$pid")
      if [[ "$_name" == "platform-api" ]]; then
        [[ $phase1_failures -gt 0 ]] && platform_rc=1
      elif [[ "$_name" == "zoa" ]]; then
        [[ $phase1_failures -gt 0 ]] && zoa_exit=1
      fi
    done
  fi

  phase1_end=$(date +%s)
  phase1_elapsed=$((phase1_end - phase1_start))
  echo ""
  echo -e "${BLUE}Phase 1 completed in ${phase1_elapsed}s${NC}"
  echo ""

  # Phase 2: Dependent tests (HCP + ROSA CLI + Monitoring)
  # Only run if Phase 1 passed and customer credentials are available
  if [[ $phase1_failures -eq 0 && "$_have_customer_creds" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}=== Phase 2: Dependent Test Suites ===${NC}"
    echo ""

    phase2_start=$(date +%s)

    if [[ "${E2E_SKIP_HCP}" == "true" ]]; then
      echo -e "${YELLOW}⊘${NC} Skipping HCP tests (E2E_SKIP_HCP=true)"
    else
      run_background_test 2 "hcp-creation" run_hcp_creation_tests
    fi

    if [[ "${E2E_SKIP_ROSA_CLI}" == "true" ]]; then
      echo -e "${YELLOW}⊘${NC} Skipping ROSA CLI tests (E2E_SKIP_ROSA_CLI=true)"
    else
      run_background_test 2 "rosa-cli" run_rosa_cli_tests
    fi

    if [[ "${E2E_SKIP_MONITORING}" == "true" ]]; then
      echo -e "${YELLOW}⊘${NC} Skipping Monitoring tests (E2E_SKIP_MONITORING=true)"
    else
      run_background_test 2 "monitoring" run_monitoring_tests
    fi

    # Wait for Phase 2 completion
    phase2_failures=0
    if [[ "${#PHASE2_PIDS[@]}" -gt 0 ]]; then
      wait_phase_jobs "Phase 2" "${PHASE2_PIDS[@]}" || phase2_failures=$?

      # Extract individual exit codes from PIDs
      for pid in "${PHASE2_PIDS[@]}"; do
        _name=$(get_name_for_pid "$pid")
        if [[ "$_name" == "hcp-creation" ]]; then
          [[ $phase2_failures -gt 0 ]] && hcp_rc=1
        elif [[ "$_name" == "rosa-cli" ]]; then
          [[ $phase2_failures -gt 0 ]] && rosa_cli_rc=1
        elif [[ "$_name" == "monitoring" ]]; then
          [[ $phase2_failures -gt 0 ]] && monitoring_rc=1
        fi
      done
    fi

    phase2_end=$(date +%s)
    phase2_elapsed=$((phase2_end - phase2_start))
    echo ""
    echo -e "${BLUE}Phase 2 completed in ${phase2_elapsed}s${NC}"
    echo ""
  elif [[ $phase1_failures -ne 0 ]]; then
    echo ""
    echo -e "${RED}Skipping Phase 2 — Phase 1 had failures${NC}"
    phase2_elapsed=0
  fi

  # Display all logs
  display_all_logs

  # Collect failure logs if any test failed
  if [[ $platform_rc -ne 0 ]] || [[ $hcp_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]] || [[ $rosa_cli_rc -ne 0 ]] || [[ $zoa_exit -ne 0 ]]; then
    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
      S3_ONLY=true "${REPO_ROOT}/scripts/dev/dump-env.sh" || true
    fi
  fi

  # Display timing summary
  parallel_end=$(date +%s)
  parallel_total=$((parallel_end - parallel_start))
  echo ""
  echo "==================================================================="
  echo "Parallel Execution Timing Summary"
  echo "==================================================================="
  echo "Phase 1 (Platform API + ZOA):        ${phase1_elapsed}s"
  echo "Phase 2 (HCP + ROSA CLI + Monitoring): ${phase2_elapsed:-0}s"
  echo "-------------------------------------------------------------------"
  echo "Total parallel execution time:        ${parallel_total}s"
  echo "==================================================================="

  echo ""
  echo "E2E results: platform=$platform_rc hcp=$hcp_rc monitoring=$monitoring_rc rosa-cli=$rosa_cli_rc zoa=$zoa_exit"
  if [[ $platform_rc -ne 0 ]] || [[ $hcp_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]] || [[ $rosa_cli_rc -ne 0 ]] || [[ $zoa_exit -ne 0 ]]; then
    exit 1
  fi
  exit 0
fi

# ==============================================================================
# Sequential Execution Mode (legacy, E2E_PARALLEL=false)
# ==============================================================================

echo ""
echo "==================================================================="
echo "Running E2E tests in SEQUENTIAL mode"
echo "==================================================================="

platform_rc=0
hcp_rc=0
monitoring_rc=0
rosa_cli_rc=0

if [[ "${E2E_SKIP_PLATFORM_API}" == "true" ]]; then
  echo ""
  echo "=== Platform API Tests ==="
  echo "Skipped (E2E_SKIP_PLATFORM_API=${E2E_SKIP_PLATFORM_API})"
else
  run_platform_api_tests || platform_rc=$?
fi

# ZOA e2e tests
zoa_exit=0
if [[ "${E2E_SKIP_ZOA}" == "true" ]]; then
  echo ""
  echo "=== ZOA Tests ==="
  echo "Skipped (E2E_SKIP_ZOA=${E2E_SKIP_ZOA})"
else
  run_zoa_tests || zoa_exit=$?
fi

# HCP creation & dependent tests (only if platform API passed)
if [[ $platform_rc -ne 0 ]]; then
  echo "Skipping HCP creation & Platform Monitoring tests — platform API tests failed (exit code: $platform_rc)"
  _have_customer_creds=false
fi

if [[ "$_have_customer_creds" == "true" ]]; then
  if [[ "${E2E_SKIP_HCP}" == "true" ]]; then
    echo ""
    echo "=== HCP Creation Tests ==="
    echo "Skipped (E2E_SKIP_HCP=${E2E_SKIP_HCP})"
  else
    run_hcp_creation_tests || hcp_rc=$?
  fi

  if [[ "${E2E_SKIP_ROSA_CLI}" == "false" ]] || [[ -z "${E2E_SKIP_ROSA_CLI:-}" ]]; then
    run_rosa_cli_tests || rosa_cli_rc=$?
  else
    echo ""
    echo "=== ROSA CLI Tests ==="
    echo "Skipped (E2E_SKIP_ROSA_CLI=${E2E_SKIP_ROSA_CLI})"
  fi

  if [[ "${E2E_SKIP_MONITORING}" == "true" ]]; then
    echo ""
    echo "=== Platform Monitoring Tests ==="
    echo "Skipped (E2E_SKIP_MONITORING=${E2E_SKIP_MONITORING})"
  else
    run_monitoring_tests || monitoring_rc=$?
  fi
fi

# HCP test failures collect logs via PRE_CLEANUP_HOOK in the test's DeferCleanup
# (before HCP deletion). Only collect here for non-HCP failures.
if [[ $platform_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]] || [[ $rosa_cli_rc -ne 0 ]]; then
    # Logs are left in S3 rather than added to public CI artifacts because
    # they may contain sensitive data that cannot be reliably redacted.
    # The S3 URIs are printed below for manual retrieval.
    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        S3_ONLY=true \
            "${REPO_ROOT}/scripts/dev/dump-env.sh" || true
    fi
fi

echo ""
echo "E2E results: platform=$platform_rc hcp=$hcp_rc monitoring=$monitoring_rc rosa-cli=$rosa_cli_rc zoa=$zoa_exit"
if [[ $platform_rc -ne 0 ]] || [[ $hcp_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]] || [[ $rosa_cli_rc -ne 0 ]] || [[ $zoa_exit -ne 0 ]]; then
    exit 1
fi