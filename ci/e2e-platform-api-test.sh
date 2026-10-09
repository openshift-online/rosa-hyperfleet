#!/bin/bash
# This is a simple e2e platform api test script.
# It verifies the platform api endpoints.
# It creates a management cluster.
# Supply already assumed credentials for an explicitly authorized service-operator
# role in the RC account. Account enrollment alone is not an operator grant.
# API_URL is the full invoke base (including any /prod stage).
# It requires the following tools:
# - aws
# - jq
# - curl (with --aws-sigv4 support)

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
  : "${AWS_ACCESS_KEY_ID:?Export assumed operator credentials}"
  : "${AWS_SECRET_ACCESS_KEY:?Export assumed operator credentials}"
  local ACCOUNT_ID
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  API_URL="${API_URL%/}"
  local SECURITY_TOKEN_HEADER=()
  if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
    SECURITY_TOKEN_HEADER=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
  fi

  log_section "Testing Platform API"
  
  log_msg "Testing API URL: $API_URL with region: $REGION"
  # Test basic API endpoints
  log_section "Testing API Health Endpoints"
  
  local counter=0 HTTP_CODE RESPONSE BODY PAYLOAD
  while true; do
    log_msg "Testing API URL: $API_URL/api/v0/live"
    if HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
      --connect-timeout 10 --max-time 30 \
      --aws-sigv4 "aws:amz:${REGION}:execute-api" \
      --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
      "${SECURITY_TOKEN_HEADER[@]}" "$API_URL/api/v0/live") && [ "$HTTP_CODE" = "200" ]; then
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
  local path
  for path in ready management_clusters; do
    if ! RESPONSE=$(curl -sS -w '\n%{http_code}' \
      --connect-timeout 10 --max-time 30 \
      --aws-sigv4 "aws:amz:${REGION}:execute-api" \
      --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
      "${SECURITY_TOKEN_HEADER[@]}" "$API_URL/api/v0/$path"); then
      log_error "Transport failure testing $path"
      return 1
    fi
    HTTP_CODE="${RESPONSE##*$'\n'}"
    BODY="${RESPONSE%$'\n'*}"
    if [ "$HTTP_CODE" != "200" ]; then
      log_error "$path returned HTTP $HTTP_CODE"
      echo "$BODY"
      return 1
    fi
    echo "$BODY"
  done
  # Create or verify management cluster
  log_section "Creating/Verifying Management Cluster"
  PAYLOAD=$(jq -n --arg id "$MANAGEMENT_CLUSTER" --arg region "$REGION" --arg account "$ACCOUNT_ID" \
    '{id: $id, region: $region, accountId: $account}')
  if ! RESPONSE=$(curl -sS -w '\n%{http_code}' -X POST "$API_URL/api/v0/management_clusters" \
    --connect-timeout 10 --max-time 30 \
    --aws-sigv4 "aws:amz:${REGION}:execute-api" \
    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
    "${SECURITY_TOKEN_HEADER[@]}" \
    -H "Content-Type: application/json" -d "$PAYLOAD"); then
    log_error "Registration transport failure"
    return 1
  fi
  HTTP_CODE="${RESPONSE##*$'\n'}"
  BODY="${RESPONSE%$'\n'*}"

  # Only the actual HTTP 409 with the API's typed conflict is idempotent success.
  if [ "$HTTP_CODE" = "409" ] && echo "$BODY" | jq -e '.kind == "Status" and .reason == "Conflict" and .code == 409 and (.message | startswith("MC-MGMT-CREATE-005:"))' >/dev/null 2>&1; then
    log_info "Management cluster already exists (this is acceptable)"
    echo "Response: $BODY"
  elif [ "$HTTP_CODE" != "201" ]; then
    log_error "Failed to create management cluster (HTTP $HTTP_CODE)"
    echo "Response: $BODY"
    return 1
  else
    log_success "Management cluster created successfully"
    echo "Response: $BODY"
  fi
  echo ""
}

# Run Platform API tests
test_platform_api "${API_URL}" "${MANAGEMENT_CLUSTER}"

echo "Done."
