#!/bin/bash
# Run e2e API tests from rosa-hyperfleet-api against the provisioned environment.
#
# API URL resolution (first match wins):
#   1. BASE_URL env var            — set by local wrapper scripts (ephemeral-env.sh, int-env.sh)
#   2. CREDS_DIR/api_url file — Prow-mounted secret for the standing int environment
#   3. SHARED_DIR terraform output — written by ephemeral-provider during CI provisioning

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

# Use the regional account profile for authenticated API calls
export AWS_PROFILE="rrp-rc"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
echo ""
echo "=== API Tests ==="
echo "===           ==="
echo "Repo: ${E2E_REPO} - Branch: ${E2E_REF}"
echo ""
git clone --depth 1 --branch "${E2E_REF}" \
  "${E2E_REPO}" "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

echo "===           ==="
echo "working commit $(git rev-parse HEAD)"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

platform_rc=0
zoa_rc=0
hcp_rc=0
monitoring_rc=0
make test-e2e-api || platform_rc=$?

# Get regional account ID for CLI tests
if [[ -z "${E2E_ACCOUNT_ID:-}" ]]; then
  export E2E_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  echo "Regional account ID: ${E2E_ACCOUNT_ID}"
fi

# --- ZOA (Zero Operator Access) E2E Tests ---
if [[ $platform_rc -ne 0 ]]; then
  echo "Skipping ZOA tests — platform API tests failed (exit code: $platform_rc)"
else
  echo ""
  echo "=== ZOA Tests ==="
  echo ""
  make test-e2e-zoa || zoa_rc=$?
fi

# --- HCP Creation E2E Tests ---
# Customer credentials are supplied via the rrp-customer AWS profile (CUSTOMER_AWS_PROFILE).
# Subprocesses use credential_process auto-refresh, avoiding the 15-minute STS TTL cliff.
# Only run if the platform API tests passed.
_have_customer_creds=false
if [[ $platform_rc -ne 0 ]]; then
  echo "Skipping HCP creation & Platform Monitoring tests — platform API tests failed (exit code: $platform_rc)"
elif aws configure export-credentials --profile rrp-customer --format process &>/dev/null; then
  export CUSTOMER_AWS_PROFILE="rrp-customer"
  echo "Customer profile rrp-customer is available"

  if [[ -z "${E2E_CUSTOMER_ACCOUNT_ID:-}" ]]; then
    export E2E_CUSTOMER_ACCOUNT_ID="$(aws sts get-caller-identity --profile rrp-customer --query Account --output text)"
    echo "Customer account ID: ${E2E_CUSTOMER_ACCOUNT_ID:0:8}..."
  fi
  _have_customer_creds=true
else
  echo "WARNING: No rrp-customer profile available — skipping HCP creation tests"
fi

# Collect DNS / external-dns diagnostics to help root-cause HCP API connection failures.
#
# Called pre-test (no args) to baseline infrastructure state, and post-failure (with
# the cluster API hostname) to check whether the A record was ever written to Route53.
#
# Five failure modes this distinguishes:
#   A) external-dns pod not running / crashlooping
#   B) external-dns IAM failure (AccessDenied on cross-account Route53 assume)
#   C) HyperShift CPO not creating DNSEndpoint CRs
#   D) Route53 zone shard missing or NS delegation broken
#   E) Pure timing — record in Route53 but DNS not yet propagated to VPC resolver
diag_dns() {
    local cluster_api_host="${1:-}"
    echo ""
    echo "=== [DIAG] DNS / external-dns state ==="

    local mc_kube_ok=false
    local mc_cluster="${CLUSTER_PREFIX:-}mc01"
    if AWS_PROFILE="rrp-mc" aws eks update-kubeconfig \
            --name "$mc_cluster" \
            --kubeconfig /tmp/mc-kubeconfig 2>&1; then
        mc_kube_ok=true
    else
        echo "[diag] Could not fetch MC kubeconfig for ${mc_cluster} — skipping kubectl checks"
    fi

    if [[ "$mc_kube_ok" == "true" ]]; then
        echo "[diag] external-dns pods:"
        KUBECONFIG=/tmp/mc-kubeconfig \
            kubectl get pods -n hypershift -l app.kubernetes.io/name=external-dns \
            -o wide 2>&1 || true

        echo "[diag] DNSEndpoint CRs:"
        KUBECONFIG=/tmp/mc-kubeconfig \
            kubectl get dnsendpoints.externaldns.k8s.io -A 2>&1 || true

        echo "[diag] external-dns logs (last 80 lines, filtered):"
        if ! KUBECONFIG=/tmp/mc-kubeconfig \
                kubectl logs -n hypershift \
                -l app.kubernetes.io/name=external-dns \
                --tail=80 --prefix 2>&1 \
                | grep -iE "error|denied|zone|record|endpoint|Route53|warn|fail"; then
            KUBECONFIG=/tmp/mc-kubeconfig \
                kubectl logs -n hypershift \
                -l app.kubernetes.io/name=external-dns \
                --tail=80 --prefix 2>&1 || true
        fi

        echo "[diag] Pod Identity associations (hypershift namespace):"
        AWS_PROFILE="rrp-mc" aws eks list-pod-identity-associations \
            --cluster-name "$mc_cluster" \
            --namespace hypershift 2>&1 || true
    fi

    echo "[diag] Route53 hosted zones in RC account:"
    AWS_PROFILE="rrp-rc" aws route53 list-hosted-zones \
        --query 'HostedZones[*].[Name,Id,Config.PrivateZone]' \
        --output table 2>&1 || true

    local base_domain
    base_domain=$(echo "${BASE_URL:-}" | sed 's|https\?://||;s|/.*||;s|^[^.]*\.||')
    if [[ -n "$base_domain" ]]; then
        echo "[diag] NS delegation for base domain ${base_domain}:"
        dig NS "${base_domain}" +short 2>&1 || nslookup -type=NS "${base_domain}" 2>&1 || true
    fi

    if [[ -n "$cluster_api_host" ]]; then
        echo "[diag] DNS resolution for: ${cluster_api_host}"
        dig A "${cluster_api_host}" +short 2>&1 || nslookup "${cluster_api_host}" 2>&1 || true

        echo "[diag] Route53 A record check for: ${cluster_api_host}"
        local cluster_label
        cluster_label=$(echo "$cluster_api_host" | cut -d. -f2)
        while IFS= read -r zone_id; do
            [[ -n "$zone_id" ]] || continue
            AWS_PROFILE="rrp-rc" aws route53 list-resource-record-sets \
                --hosted-zone-id "$zone_id" \
                --query "ResourceRecordSets[?Name=='${cluster_api_host}.']" \
                --output json 2>&1 || true
        done < <(AWS_PROFILE="rrp-rc" aws route53 list-hosted-zones \
            --query "HostedZones[?contains(Name, '${cluster_label}')].Id" \
            --output text 2>&1) || true
    fi

    echo "=== [DIAG] end ==="
    echo ""
}

if [[ "$_have_customer_creds" == "true" ]]; then
  test_hcp_creation() {
    echo ""
    echo "=== HCP Creation Tests ==="

    local HCP_CLUSTER_NAME="e2e-$(date +%s)"

    CLI_WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "${CLI_WORK_DIR}"; rm -rf "${WORK_DIR}"' EXIT
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

    # Collect cluster logs before HCP cleanup so the HCP namespace is captured.
    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        export PRE_CLEANUP_HOOK="S3_ONLY=true ${REPO_ROOT}/scripts/dev/collect-cluster-logs.sh"
    fi

    export GINKGO_NO_COLOR=TRUE
    if [[ -n "${E2E_SKIP_CLEANUP:-}" ]]; then
      echo "E2E_SKIP_CLEANUP is set — cleanup specs will be skipped"
      export E2E_LABEL_FILTER='!cleanup'
    fi
    diag_dns
    _hcp_rc=0
    make test-e2e-cli || _hcp_rc=$?
    if [[ $_hcp_rc -ne 0 ]]; then
        # The zone shard suffix in the hostname comes from HyperShift's baseDomain config;
        # the actual host appears in the make test-e2e-cli output above. This approximation
        # is best-effort — the Route53 zone listing in diag_dns will surface the right zone.
        _api_host="api.${HCP_CLUSTER_NAME}.${CLUSTER_PREFIX:-}.${AWS_DEFAULT_REGION:-us-east-1}.ci00.rosa.devshift.net"
        echo "[diag] HCP test failed (exit ${_hcp_rc}) — running DNS diagnostics for: ${_api_host}"
        diag_dns "$_api_host"
        return $_hcp_rc
    fi

    echo "HCP creation test completed for: ${HCP_CLUSTER_NAME}"
  }

  test_hcp_creation || hcp_rc=$?

  echo ""
  echo "=== Platform Monitoring Tests ==="
  echo ""
  # Run with an explicit 25m timeout: the two Eventually("10m",...) specs need at
  # least 21m of suite time; the remote Makefile target uses --timeout=5m which
  # fires before either spec can complete.
  E2E_RHOBS_API_URL="${RHOBS_API_URL}" \
    ginkgo --timeout=25m -v --no-color --label-filter=Observability \
    ./test/e2e/... \
    || monitoring_rc=$?
fi

# HCP test failures collect logs via PRE_CLEANUP_HOOK in the test's DeferCleanup
# (before HCP deletion). Only collect here for non-HCP failures.
if [[ $platform_rc -ne 0 ]] || [[ $zoa_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]]; then
    # Logs are left in S3 rather than added to public CI artifacts because
    # they may contain sensitive data that cannot be reliably redacted.
    # The S3 URIs are printed below for manual retrieval.
    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        S3_ONLY=true \
            "${REPO_ROOT}/scripts/dev/collect-cluster-logs.sh" || true
    fi
fi

echo ""
echo "E2E results: platform=$platform_rc zoa=$zoa_rc hcp=$hcp_rc monitoring=$monitoring_rc"
if [[ $platform_rc -ne 0 ]] || [[ $zoa_rc -ne 0 ]] || [[ $hcp_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]]; then
    exit 1
fi
