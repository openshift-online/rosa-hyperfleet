#!/bin/bash
# Run e2e API tests from rosa-regional-platform-api against the provisioned environment.
# API URL is read from ${CREDS_DIR}/api_url if available, otherwise from
# SHARED_DIR/regional-terraform-outputs.json (written by ci/ephemeral-provider/main.py --save-state).

set -euo pipefail

CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

if [[ -n "${BASE_URL:-}" ]]; then
  echo "Using BASE_URL from environment: ${BASE_URL}"
else
  if [[ -r "${CREDS_DIR}/api_url" ]]; then
    echo "Using API URL from ${CREDS_DIR}/api_url (pre-existing environment)"
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

# Set up AWS credentials for authenticated API calls (e.g. aws sts get-caller-identity)
if [[ -r "${CREDS_DIR}/regional_access_key" ]]; then
  export AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/regional_access_key")"
  export AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/regional_secret_key")"
  export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
  echo "AWS credentials loaded from ${CREDS_DIR}"
else
  echo "WARNING: No credentials found at ${CREDS_DIR}/regional_access_key"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_REF="${API_REF:-main}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
git clone --depth 1 --branch "${API_REF}" \
  https://github.com/openshift-online/rosa-regional-platform-api.git "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

rc=0
make test-e2e || rc=$?

if [[ $rc -ne 0 ]]; then
    echo ""
    echo "E2E tests failed (exit code: $rc). Collecting cluster logs..."

    # Pre-existing environment (integration): bare cluster names (regional, mc01)
    # Ephemeral environment: ci_prefix-based names derived from BUILD_ID
    if [[ -r "${CREDS_DIR}/api_url" ]]; then
        export CLUSTER_PREFIX=""
    elif [[ -n "${BUILD_ID:-}" ]]; then
        hash="$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-6)" \
            || { echo "WARNING: sha256sum failed — skipping log collection"; hash=""; }
        if [[ -n "$hash" ]]; then
            export CLUSTER_PREFIX="ci-${hash}-"
        fi
    else
        echo "WARNING: BUILD_ID not set — skipping log collection"
    fi

    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        # Logs are left in S3 rather than added to public CI artifacts because
        # they may contain sensitive data (e.g. maestro secrets) that cannot be
        # reliably redacted. The S3 URIs are printed below for manual retrieval.
        S3_ONLY=true \
            "${REPO_ROOT}/scripts/dev/collect-cluster-logs.sh" || true
    fi
    exit $rc
fi
