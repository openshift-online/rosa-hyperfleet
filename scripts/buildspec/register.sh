#!/usr/bin/env bash
# Register a Management Cluster with the Regional Cluster API.
# Called from: terraform/config/pipeline-management-cluster/buildspec-register.yml
set -euo pipefail

echo "=========================================="
echo "Register MC with Regional Cluster API"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Load terraform variables from deploy/ JSON
source scripts/pipeline-common/load-deploy-config.sh management

# Read delete flag from config (GitOps-driven deletion)
ENVIRONMENT="${ENVIRONMENT:-staging}"
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")

# Manual override: IS_DESTROY pipeline variable takes precedence
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

echo ""
if [ "${DELETE_FLAG}" == "true" ]; then
    echo ">>> MODE: TEARDOWN <<<"
else
    echo ">>> MODE: PROVISION <<<"
fi
echo ""

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "delete=true in config — skipping MC registration (cluster is being destroyed)"
    exit 0
fi

# =====================================================================
# Read API Gateway URL and CloudFront domain from RC terraform state
# =====================================================================

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

# Resolve RC state key from regional config
RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json"
if [ ! -f "$RC_CONFIG_FILE" ]; then
    echo "ERROR: Regional cluster config not found: $RC_CONFIG_FILE"
    exit 1
fi
RC_REGIONAL_ID=$(jq -r '.regional_id' "$RC_CONFIG_FILE")
echo "Resolved RC regional_id from config: $RC_REGIONAL_ID"

# Assume RC account to read terraform outputs and call API
use_rc_account

RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
RC_STATE_KEY="regional-cluster/${RC_REGIONAL_ID}.tfstate"

echo "RC state:"
echo "  Bucket: $RC_STATE_BUCKET"
echo "  Key: $RC_STATE_KEY"
echo "  Region: $TARGET_REGION"
echo ""

# Init RC terraform config to read API Gateway URL and OIDC CloudFront domain
(
    cd terraform/config/regional-cluster
    terraform init -reconfigure \
        -backend-config="bucket=${RC_STATE_BUCKET}" \
        -backend-config="key=${RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true"
)

API_GATEWAY_URL=$(cd terraform/config/regional-cluster && terraform output -raw api_gateway_invoke_url)

CLOUDFRONT_DOMAIN=$(cd terraform/config/regional-cluster && terraform output -raw oidc_cloudfront_domain)

if [ -z "$CLOUDFRONT_DOMAIN" ]; then
    echo "ERROR: Failed to read oidc_cloudfront_domain from RC terraform state"
    exit 1
fi

CLOUDFRONT_URL="https://${CLOUDFRONT_DOMAIN}"
echo "CloudFront URL: $CLOUDFRONT_URL"
echo ""

if [ -z "$API_GATEWAY_URL" ]; then
    echo "ERROR: Failed to read api_gateway_invoke_url from RC terraform state"
    exit 1
fi

echo "API Gateway URL: $API_GATEWAY_URL"
echo ""

# ======================================================
# Check API Gateway /live is ready before registering
# ======================================================
set +e
MAX_RETRIES=10
RETRY_DELAY=30
RETRY_COUNT=0
LIVE_OK=false

echo "Checking API Gateway /live endpoint..."
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT/$MAX_RETRIES..."

    SECURITY_TOKEN_HEADER=()
    if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
        SECURITY_TOKEN_HEADER=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    fi

    HTTP_CODE=$(curl -s -o /tmp/register-response.json -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        --aws-sigv4 "aws:amz:${TARGET_REGION}:execute-api" \
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        "${SECURITY_TOKEN_HEADER[@]}" \
        -X GET "$API_GATEWAY_URL/api/v0/live")

    if [ "$HTTP_CODE" = "200" ]; then
        echo "API Gateway /live returned 200 — ready."
        LIVE_OK=true
        break
    fi
    echo "HTTP $HTTP_CODE (expected 200), retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
done
set -e

if [ "$LIVE_OK" != "true" ]; then
    echo "ERROR: API Gateway /live did not return 200 after $MAX_RETRIES attempts"
    exit 1
fi

# =====================================================================
# Register Management Cluster as consumer
# =====================================================================
echo "Registering management cluster '${CLUSTER_ID}' with Regional Cluster API..."

REGISTER_URL="${API_GATEWAY_URL}/api/v0/management_clusters"
PAYLOAD=$(cat <<EOJSON
{
  "name": "${CLUSTER_ID}",
  "labels": {
    "cluster_type": "management",
    "management_id": "${CLUSTER_ID}",
    "region": "${TARGET_REGION}",
    "alias": "${MANAGEMENT_ID}",
    "cloudfront_url": "${CLOUDFRONT_URL}"
  }
}
EOJSON
)

echo "POST $REGISTER_URL"
echo "Payload: $PAYLOAD"
echo ""

# Retry registration to handle transient failures (e.g. Maestro still
# starting after RC bootstrap — the /live check only validates the
# Platform API pod, not downstream dependencies like Maestro).
set +e
REG_MAX_RETRIES=10
REG_RETRY_DELAY=30
REG_RETRY_COUNT=0
REG_OK=false

while [ $REG_RETRY_COUNT -lt $REG_MAX_RETRIES ]; do
    REG_RETRY_COUNT=$((REG_RETRY_COUNT + 1))
    echo "Registration attempt $REG_RETRY_COUNT/$REG_MAX_RETRIES..."

    # Use curl with AWS SigV4 signing (built into curl, no extra deps)
    # Session token header is required when using assumed-role (temporary)
    # credentials but must be omitted for static IAM user credentials.
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

    RESPONSE=$(cat /tmp/register-response.json)
    echo "HTTP Status: $HTTP_CODE"
    echo "Response: $RESPONSE"
    echo ""

    # 201 = created, 409/502 = already exists (both are fine)
    if [ "$HTTP_CODE" = "201" ]; then
        echo "Management cluster '${CLUSTER_ID}' registered successfully."
        REG_OK=true
        break
    elif [ "$HTTP_CODE" = "409" ] || [ "$HTTP_CODE" = "502" ]; then
        echo "Management cluster '${CLUSTER_ID}' is already registered (HTTP $HTTP_CODE). Skipping."
        if [ "$HTTP_CODE" = "502" ]; then
            echo "WARNING: Maestro returned 502 for 'already exists' — this should be a 409 Conflict."
            echo "  This indicates a bug in Maestro or the API Gateway configuration."
        fi
        REG_OK=true
        break
    fi

    # 500 with maestro-error is transient during startup; retry
    echo "Registration failed (HTTP $HTTP_CODE), retrying in ${REG_RETRY_DELAY}s..."
    sleep $REG_RETRY_DELAY
done
set -e

if [ "$REG_OK" != "true" ]; then
    echo "ERROR: Registration failed after $REG_MAX_RETRIES attempts (last HTTP $HTTP_CODE)"
    echo "Response: $RESPONSE"
    exit 1
fi
echo "Management cluster registration complete."