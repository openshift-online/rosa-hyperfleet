#!/bin/bash
# E2E test for SNS alerting fan-out infrastructure.
# Validates that the SNS topic, KMS key, IAM role, and alert delivery pipeline
# are correctly provisioned and functional.
#
# Required tools: aws, jq
# Required AWS profile: rrp-rc (regional cluster account)
#
# Input resolution for REGIONAL_ID (first match wins):
#   1. REGIONAL_ID env var
#   2. cluster_name from ${SHARED_DIR}/regional-terraform-outputs.json
#   3. Default: "regional"

set -euo pipefail

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
export AWS_PROFILE="${AWS_PROFILE:-rrp-rc}"

# --- Input resolution ---

if [[ -n "${REGIONAL_ID:-}" ]]; then
  echo "Using REGIONAL_ID from environment: ${REGIONAL_ID}"
elif [[ -n "${SHARED_DIR:-}" ]]; then
  TF_OUTPUTS="${SHARED_DIR}/regional-terraform-outputs.json"
  if [[ -r "${TF_OUTPUTS}" ]]; then
    REGIONAL_ID="$(jq -r '.cluster_name.value // empty' "${TF_OUTPUTS}")"
  fi
fi
REGIONAL_ID="${REGIONAL_ID:-regional}"
echo "REGIONAL_ID: ${REGIONAL_ID}"
echo "REGION: ${REGION}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "ACCOUNT_ID: ${ACCOUNT_ID}"

TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${REGIONAL_ID}-alerts"
TIMESTAMP="$(date +%s)"

# --- State for cleanup ---

QUEUE_URL=""
SUBSCRIPTION_ARN=""

# --- Logger helpers ---

log_error() { echo "ERROR: $*" >&2; }
log_success() { echo "OK: $*"; }
log_section() { echo ""; echo "=== $* ==="; }
log_msg() { echo "  $*"; }

# --- Cleanup trap ---

cleanup() {
  echo ""
  echo "--- Cleanup ---"
  if [[ -n "${SUBSCRIPTION_ARN}" ]]; then
    echo "Deleting SNS subscription ${SUBSCRIPTION_ARN}..."
    aws sns unsubscribe --subscription-arn "${SUBSCRIPTION_ARN}" --region "${REGION}" 2>/dev/null || true
  fi
  if [[ -n "${QUEUE_URL}" ]]; then
    echo "Deleting SQS queue ${QUEUE_URL}..."
    aws sqs delete-queue --queue-url "${QUEUE_URL}" --region "${REGION}" 2>/dev/null || true
  fi
  echo "Cleanup done."
}
trap cleanup EXIT

# --- Feature gate: skip if SNS alerting is not enabled ---

if ! aws ssm get-parameter \
    --name "/${REGIONAL_ID}/alerting/sns-topic-arn" \
    --region "${REGION}" &>/dev/null; then
  echo "SNS alerting not enabled (SSM parameter not found). Skipping test."
  exit 0
fi

# =============================================================================
# Phase A: Infrastructure Verification
# =============================================================================

FAILURES=0

verify_sns_topic() {
  log_section "Verifying SNS Topic"

  local attrs
  if ! attrs="$(aws sns get-topic-attributes \
      --topic-arn "${TOPIC_ARN}" \
      --region "${REGION}" 2>&1)"; then
    log_error "SNS topic does not exist: ${TOPIC_ARN}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local kms_key
  kms_key="$(echo "${attrs}" | jq -r '.Attributes.KmsMasterKeyId // empty')"
  if [[ -z "${kms_key}" ]]; then
    log_error "SNS topic is not KMS-encrypted"
    FAILURES=$((FAILURES + 1))
    return
  fi

  log_success "SNS topic exists and is KMS-encrypted (key: ${kms_key})"
}

verify_kms_key() {
  log_section "Verifying KMS Key"

  local key_info
  if ! key_info="$(aws kms describe-key \
      --key-id "alias/${REGIONAL_ID}-sns-alerts" \
      --region "${REGION}" 2>&1)"; then
    log_error "KMS key alias/${REGIONAL_ID}-sns-alerts not found"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local key_state
  key_state="$(echo "${key_info}" | jq -r '.KeyMetadata.KeyState')"
  if [[ "${key_state}" != "Enabled" ]]; then
    log_error "KMS key is not enabled (state: ${key_state})"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local rotation
  rotation="$(aws kms get-key-rotation-status \
      --key-id "alias/${REGIONAL_ID}-sns-alerts" \
      --region "${REGION}" | jq -r '.KeyRotationEnabled')"
  if [[ "${rotation}" != "true" ]]; then
    log_error "KMS key rotation is not enabled"
    FAILURES=$((FAILURES + 1))
    return
  fi

  log_success "KMS key exists, enabled, rotation on"
}

verify_ssm_parameter() {
  log_section "Verifying SSM Parameter"

  local param_value
  param_value="$(aws ssm get-parameter \
      --name "/${REGIONAL_ID}/alerting/sns-topic-arn" \
      --query 'Parameter.Value' \
      --output text \
      --region "${REGION}" 2>&1)" || {
    log_error "SSM parameter /${REGIONAL_ID}/alerting/sns-topic-arn not found"
    FAILURES=$((FAILURES + 1))
    return
  }

  if [[ "${param_value}" != "${TOPIC_ARN}" ]]; then
    log_error "SSM parameter value mismatch: expected ${TOPIC_ARN}, got ${param_value}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  log_success "SSM parameter matches expected topic ARN"
}

verify_iam_role() {
  log_section "Verifying IAM Role"

  local role_name="${REGIONAL_ID}-alertmanager-sns"
  local role_info
  if ! role_info="$(aws iam get-role --role-name "${role_name}" 2>&1)"; then
    log_error "IAM role ${role_name} not found"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local trust_policy
  trust_policy="$(echo "${role_info}" | jq -r '.Role.AssumeRolePolicyDocument')"
  if ! echo "${trust_policy}" | jq -e '.Statement[] | select(.Principal.Service == "pods.eks.amazonaws.com")' &>/dev/null; then
    log_error "IAM role trust policy does not allow pods.eks.amazonaws.com"
    FAILURES=$((FAILURES + 1))
    return
  fi

  log_success "IAM role exists with correct trust policy"
}

verify_pod_identity() {
  log_section "Verifying EKS Pod Identity Association"

  local associations
  associations="$(aws eks list-pod-identity-associations \
      --cluster-name "${REGIONAL_ID}" \
      --namespace monitoring \
      --service-account monitoring-alertmanager \
      --region "${REGION}" 2>&1)" || {
    log_error "Failed to list pod identity associations for cluster ${REGIONAL_ID}"
    FAILURES=$((FAILURES + 1))
    return
  }

  local count
  count="$(echo "${associations}" | jq '.associations | length')"
  if [[ "${count}" -eq 0 ]]; then
    log_error "No pod identity association found for monitoring/monitoring-alertmanager"
    FAILURES=$((FAILURES + 1))
    return
  fi

  log_success "Pod identity association exists (${count} found)"
}

# Run Phase A checks
verify_sns_topic
verify_kms_key
verify_ssm_parameter
verify_iam_role
verify_pod_identity

if [[ "${FAILURES}" -gt 0 ]]; then
  echo ""
  log_error "Phase A failed: ${FAILURES} infrastructure check(s) failed"
  exit 1
fi
echo ""
log_success "Phase A passed: all infrastructure checks passed"

# =============================================================================
# Phase B: End-to-End Delivery Validation
# =============================================================================

log_section "Phase B: End-to-End Delivery Validation"

QUEUE_NAME="${REGIONAL_ID}-e2e-alert-test-${TIMESTAMP}"
TEST_ID="e2e-sns-test-${TIMESTAMP}"

# Step 1: Create temporary SQS queue
log_msg "Creating temporary SQS queue: ${QUEUE_NAME}"
QUEUE_URL="$(aws sqs create-queue \
    --queue-name "${QUEUE_NAME}" \
    --region "${REGION}" \
    --query 'QueueUrl' \
    --output text)"
echo "  Queue URL: ${QUEUE_URL}"

QUEUE_ARN="$(aws sqs get-queue-attributes \
    --queue-url "${QUEUE_URL}" \
    --attribute-names QueueArn \
    --region "${REGION}" \
    --query 'Attributes.QueueArn' \
    --output text)"
echo "  Queue ARN: ${QUEUE_ARN}"

# Step 2: Set queue policy allowing SNS to send messages
log_msg "Setting SQS queue policy..."
QUEUE_POLICY=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "sns.amazonaws.com"
      },
      "Action": "sqs:SendMessage",
      "Resource": "${QUEUE_ARN}",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "${TOPIC_ARN}"
        }
      }
    }
  ]
}
POLICY
)

aws sqs set-queue-attributes \
    --queue-url "${QUEUE_URL}" \
    --attributes "{\"Policy\": $(echo "${QUEUE_POLICY}" | jq -c '.' | jq -Rs '.')}" \
    --region "${REGION}"

# Step 3: Subscribe SQS to SNS
log_msg "Subscribing SQS queue to SNS topic..."
SUBSCRIPTION_ARN="$(aws sns subscribe \
    --topic-arn "${TOPIC_ARN}" \
    --protocol sqs \
    --notification-endpoint "${QUEUE_ARN}" \
    --return-subscription-arn \
    --region "${REGION}" \
    --query 'SubscriptionArn' \
    --output text)"
echo "  Subscription ARN: ${SUBSCRIPTION_ARN}"

# Step 4: Publish test message
log_msg "Publishing test message to SNS topic..."
TEST_MESSAGE="{\"source\":\"e2e-test\",\"test_id\":\"${TEST_ID}\",\"regional_id\":\"${REGIONAL_ID}\",\"timestamp\":\"${TIMESTAMP}\"}"

aws sns publish \
    --topic-arn "${TOPIC_ARN}" \
    --message "${TEST_MESSAGE}" \
    --subject "e2e-test-alert" \
    --region "${REGION}" \
    --output text > /dev/null

log_success "Message published"

# Step 5: Poll SQS for the message
log_msg "Polling SQS for test message (timeout: 60s)..."
RECEIVED=false
ELAPSED=0
MAX_WAIT=60

while [[ "${ELAPSED}" -lt "${MAX_WAIT}" ]]; do
  if ! MESSAGES="$(aws sqs receive-message \
      --queue-url "${QUEUE_URL}" \
      --wait-time-seconds 5 \
      --max-number-of-messages 1 \
      --region "${REGION}")"; then
    log_error "SQS receive-message failed (retrying)"
    ELAPSED=$((ELAPSED + 5))
    continue
  fi

  if echo "${MESSAGES}" | jq -e '.Messages[0]' &>/dev/null; then
    BODY="$(echo "${MESSAGES}" | jq -r '.Messages[0].Body')"
    if echo "${BODY}" | jq -r '.Message // empty' | grep -q "${TEST_ID}"; then
      RECEIVED=true
      break
    fi
  fi

  ELAPSED=$((ELAPSED + 5))
  log_msg "  Waiting... (${ELAPSED}s/${MAX_WAIT}s)"
done

if [[ "${RECEIVED}" != "true" ]]; then
  log_error "Test message not received in SQS within ${MAX_WAIT}s"
  exit 1
fi

echo ""
log_success "Phase B passed: test message received in SQS"
echo ""
log_success "All SNS alerting e2e tests passed"
