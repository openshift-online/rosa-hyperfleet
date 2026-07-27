#!/usr/bin/env bash
# Register a Management Cluster with the Regional Cluster API.
# Called from: terraform/config/pipeline-management-cluster/buildspec-register.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

ENVIRONMENT="${ENVIRONMENT:-staging}"
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "delete=true — skipping MC registration"
    exit 0
fi

echo "Registering MC ${CLUSTER_ID} with RC API"

# Read API Gateway URL and CloudFront domain from RC terraform state
RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json"
if [ ! -f "$RC_CONFIG_FILE" ]; then
    echo "ERROR: RC config not found: $RC_CONFIG_FILE" >&2
    exit 1
fi
RC_REGIONAL_ID=$(jq -r '.regional_id' "$RC_CONFIG_FILE")

use_rc_account

RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
RC_STATE_KEY="regional-cluster/${RC_REGIONAL_ID}.tfstate"

(
    cd terraform/config/regional-cluster
    terraform init -reconfigure \
        -backend-config="bucket=${RC_STATE_BUCKET}" \
        -backend-config="key=${RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true"
)

# RC and MC pipelines run in parallel — retry until outputs appear (up to 45 min)
_REG_MAX_RETRIES=90
_REG_RETRY_DELAY=30
_REG_RETRY_COUNT=0
API_GATEWAY_URL=""

while [ $_REG_RETRY_COUNT -lt $_REG_MAX_RETRIES ]; do
    _REG_RETRY_COUNT=$((_REG_RETRY_COUNT + 1))
    API_GATEWAY_URL=$(cd terraform/config/regional-cluster && terraform output -raw api_gateway_invoke_url 2>/dev/null || true)
    if [ -n "$API_GATEWAY_URL" ]; then
        break
    fi
    echo "RC outputs not ready (attempt ${_REG_RETRY_COUNT}/${_REG_MAX_RETRIES}), retrying in ${_REG_RETRY_DELAY}s..."
    sleep "$_REG_RETRY_DELAY"
done

if [ -z "$API_GATEWAY_URL" ]; then
    echo "ERROR: api_gateway_invoke_url not available after $((_REG_MAX_RETRIES * _REG_RETRY_DELAY / 60))+ minutes" >&2
    exit 1
fi

# Wait for API Gateway /live endpoint
set +e
MAX_RETRIES=10
RETRY_DELAY=30
RETRY_COUNT=0
LIVE_OK=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))

    SECURITY_TOKEN_HEADER=()
    if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
        SECURITY_TOKEN_HEADER=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        --aws-sigv4 "aws:amz:${TARGET_REGION}:execute-api" \
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        "${SECURITY_TOKEN_HEADER[@]}" \
        -X GET "$API_GATEWAY_URL/api/v0/live")

    if [ "$HTTP_CODE" = "200" ]; then
        LIVE_OK=true
        break
    fi
    echo "/live returned $HTTP_CODE (attempt $RETRY_COUNT/$MAX_RETRIES), retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
done
set -e

if [ "$LIVE_OK" != "true" ]; then
    echo "ERROR: /live did not return 200 after $MAX_RETRIES attempts" >&2
    exit 1
fi

# Register management cluster
REGISTER_URL="${API_GATEWAY_URL}/api/v0/management_clusters"
PAYLOAD=$(cat <<EOJSON
{
  "id": "${CLUSTER_ID}",
  "region": "${TARGET_REGION}",
  "accountId": "${TARGET_ACCOUNT_ID}"
}
EOJSON
)

set +e
REG_MAX_RETRIES=10
REG_RETRY_DELAY=30
REG_RETRY_COUNT=0
REG_OK=false

while [ $REG_RETRY_COUNT -lt $REG_MAX_RETRIES ]; do
    REG_RETRY_COUNT=$((REG_RETRY_COUNT + 1))

    SECURITY_TOKEN_HEADER=()
    if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
        SECURITY_TOKEN_HEADER=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    fi

    HTTP_CODE=$(curl -s -o /tmp/register-response.json -w "%{http_code}" \
        --aws-sigv4 "aws:amz:${TARGET_REGION}:execute-api" \
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        "${SECURITY_TOKEN_HEADER[@]}" \
        -X POST "$REGISTER_URL" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    # 201 = created, 409 = already exists
    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
        REG_OK=true
        break
    fi
    # 502 may indicate "already exists" behind a gateway error — check response body
    if [ "$HTTP_CODE" = "502" ] && grep -qi "already exists" /tmp/register-response.json 2>/dev/null; then
        REG_OK=true
        break
    fi

    echo "Registration returned $HTTP_CODE (attempt $REG_RETRY_COUNT/$REG_MAX_RETRIES), retrying in ${REG_RETRY_DELAY}s..."
    sleep $REG_RETRY_DELAY
done
set -e

if [ "$REG_OK" != "true" ]; then
    echo "ERROR: Registration failed after $REG_MAX_RETRIES attempts (HTTP $HTTP_CODE)" >&2
    cat /tmp/register-response.json >&2
    exit 1
fi

# Wire SNS→SQS subscriptions.
#
# Both subscriptions are created here — after API registration succeeds — because
# this is the first point in the pipeline where all four resources are guaranteed
# to exist:
#   Stage 1 (Deploy MC):                    MC SQS + MC SNS created
#   Stage 2 (Provision-KubeApplier-DynamoDB): RC SNS + RC SQS created
#   Stage 4 (Register, this script):        safe to subscribe
#
# This script already runs under RC account credentials (use_rc_account above).
# The MC status topic policy grants sns:Subscribe to the RC account
# (AllowRCAccountSubscribe), so both subscriptions can be created from here.
#
# AWS automatically removes subscriptions when their SNS topic is deleted, so
# no explicit teardown is needed — Terraform destroying a topic cleans up its
# subscriptions for free.

SPECS_TOPIC_ARN="arn:aws:sns:${TARGET_REGION}:${RESOLVED_REGIONAL_ACCOUNT_ID}:${CLUSTER_ID}-specs-notifications"
SPECS_QUEUE_ARN="arn:aws:sqs:${TARGET_REGION}:${TARGET_ACCOUNT_ID}:${CLUSTER_ID}-specs-notifications"
STATUS_TOPIC_ARN="arn:aws:sns:${TARGET_REGION}:${TARGET_ACCOUNT_ID}:${CLUSTER_ID}-status-notifications"
OPERATOR_REPLICA_COUNT=$(jq -r '.operator_replica_count // 3' "$DEPLOY_CONFIG_FILE")

echo "Subscribing specs queue to specs topic"
aws sns subscribe \
    --topic-arn "$SPECS_TOPIC_ARN" \
    --protocol sqs \
    --notification-endpoint "$SPECS_QUEUE_ARN" \
    --attributes '{"RawMessageDelivery":"true"}' \
    --region "$TARGET_REGION"

echo "Subscribing ${OPERATOR_REPLICA_COUNT} operator replica queue(s) to status topic"
for i in $(seq 0 $((OPERATOR_REPLICA_COUNT - 1))); do
    STATUS_QUEUE_ARN="arn:aws:sqs:${TARGET_REGION}:${RESOLVED_REGIONAL_ACCOUNT_ID}:${RC_REGIONAL_ID}-hyperfleet-operator-${i}"
    echo "  Subscribing replica ${i}: ${STATUS_QUEUE_ARN}"
    aws sns subscribe \
        --topic-arn "$STATUS_TOPIC_ARN" \
        --protocol sqs \
        --notification-endpoint "$STATUS_QUEUE_ARN" \
        --attributes '{"RawMessageDelivery":"true"}' \
        --region "$TARGET_REGION"
done

echo "SNS→SQS subscriptions wired successfully"
