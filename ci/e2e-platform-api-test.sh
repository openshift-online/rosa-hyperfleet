#!/bin/bash
# This is a simple e2e platform api test script.
# It verifies the platform api endpoints.
# It creates a management cluster.
# It is meant to be run from the regional account.
# It requires the following tools:
# - aws
# - jq
# - awscurl
# - date
# - cat
# - echo

set -euo pipefail

# Use AWS_REGION from environment or default
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
API_URL="${1}"
MANAGEMENT_CLUSTER="${2:-mc01}"

# Logger functions
log_error() {
  echo "❌ ERROR: $*" >&2
}

log_success() {
  echo "✅ $*"
}

log_info() {
  echo "ℹ️  $*"
}

log_msg() {
  echo "ℹ   $*"
}

log_section() {
  echo ""
  echo "=== $* ==="
}

# Function to test Platform API endpoints
test_platform_api() {

  local API_URL="${1}"
  local MANAGEMENT_CLUSTER="${2:-mc01}"
  
  log_section "Testing Platform API"
  
  log_msg "Testing API URL: $API_URL with region: $REGION"
  # Test basic API endpoints
  log_section "Testing API Health Endpoints"
  
  set +e # allow awscurl to fail without exiting (disable errexit)
  counter=0
  while true; do
    log_msg "Testing API URL: $API_URL/prod/v0/live"
    awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/v0/live"
    r=$?
    if [ "$r" -eq 0 ]; then
      log_success "API is healthy"
      break
    else
      log_msg "API is not healthy, retrying in 30 seconds"
      sleep 30
      counter=$((counter + 1))
      if [ $counter -ge 10 ]; then
        log_error "API is not healthy after 10 retries (5m), exiting"
        exit 1
      fi
    fi
  done
  set -e # re-enable exit on error (errexit)

  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/v0/ready"
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/api/v0/management_clusters"
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/api/v0/resource_bundles"
  # awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/work"
  # awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/clusters"
  # Create or verify management cluster
  log_section "Creating/Verifying Management Cluster"
  local RESPONSE=$(awscurl --fail-with-body -X POST "$API_URL/prod/api/v0/management_clusters" \
    --service execute-api \
    --region "$REGION" \
    -H "Content-Type: application/json" \
    -d '{"name": "'$MANAGEMENT_CLUSTER'", "labels": {"cluster_type": "management", "cluster_id": "'$MANAGEMENT_CLUSTER'"}}' \
    2>&1)
  local EXIT_CODE=$?

  # Check if the consumer already exists (this is acceptable)
  if echo "$RESPONSE" | grep -qiE '"reason":"This Consumer already exists"'; then
    log_info "Management cluster already exists (this is acceptable)"
    echo "Response: $RESPONSE"
  elif [ $EXIT_CODE -ne 0 ]; then
    log_error "Failed to create management cluster (exit code: $EXIT_CODE)"
    echo "Response: $RESPONSE"
    return 1
  elif echo "$RESPONSE" | grep -qiE '(error|failed|exception|invalid)'; then
    log_error "API returned an error response"
    echo "Response: $RESPONSE"
    return 1
  else
    log_success "Management cluster created successfully"
    echo "Response: $RESPONSE"
  fi
  echo ""
}

# Run Platform API tests
test_platform_api "${API_URL}" "${MANAGEMENT_CLUSTER}"

echo "Done."
