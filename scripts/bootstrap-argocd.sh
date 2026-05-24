#!/bin/bash
# Bootstrap ArgoCD - run from terraform/config/{cluster-type} after terraform apply as it uses the output
set -euo pipefail

CLUSTER_TYPE="${1:-}"

# Set defaults from environment variables
ENVIRONMENT="${ENVIRONMENT:-integration}"
# Prefer existing REGION_DEPLOYMENT, then AWS CLI, then default (handles empty CLI output)
AWS_CLI_REGION=$(aws configure get region 2>/dev/null || true)
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ -z "$CLUSTER_TYPE" ]]; then
    echo "Usage: ENVIRONMENT=<env> REGION_DEPLOYMENT=<alias> AWS_REGION=<region> $0 <cluster-type>"
    echo ""
    echo "Arguments:"
    echo "  cluster-type: management-cluster or regional-cluster"
    echo ""
    echo "Required environment variables:"
    echo "  ENVIRONMENT - Environment name (integration, staging, production)"
    echo "  REGION_DEPLOYMENT - Region directory identifier"
    echo "  AWS_REGION - AWS region for operations"
    echo ""
    echo "All environment variables have defaults if not specified."
    exit 1
fi

TERRAFORM_DIR="terraform/config/${CLUSTER_TYPE}"

# Read terraform outputs BEFORE assuming role
# (terraform state is in central account, so we need central account creds to read it)
cd ${TERRAFORM_DIR}/

OUTPUTS=$(terraform output -json)

# Handle cross-account role assumption if ASSUME_ROLE_ARN is set
# This is used when the script runs in CodeBuild to bootstrap a cluster in a different account
# We assume the role AFTER reading terraform outputs because:
# - Terraform state is in central account S3, needs central account creds
# - ECS cluster/logs are in target account, need target account creds
if [[ -n "${ASSUME_ROLE_ARN:-}" ]]; then
    echo "Assuming role for AWS resource access: $ASSUME_ROLE_ARN"

    # Attempt role assumption and capture output
    if ! CREDS=$(aws sts assume-role \
        --role-arn "$ASSUME_ROLE_ARN" \
        --role-session-name "bootstrap-argocd" \
        --output json 2>&1); then
        echo "Failed to assume role: $ASSUME_ROLE_ARN"
        echo "AWS CLI error output:"
        echo "$CREDS"
        exit 1
    fi

    # Validate credentials were returned
    if ! echo "$CREDS" | jq -e '.Credentials' >/dev/null 2>&1; then
        echo "Role assumption succeeded but credentials not found in response"
        echo "Role ARN: $ASSUME_ROLE_ARN"
        echo "Response:"
        echo "$CREDS"
        exit 1
    fi

    # Extract credentials using -er to fail on null/missing values
    if ! AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -er '.Credentials.AccessKeyId'); then
        echo "Failed to extract AccessKeyId from assume-role response"
        exit 1
    fi

    if ! AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -er '.Credentials.SecretAccessKey'); then
        echo "Failed to extract SecretAccessKey from assume-role response"
        exit 1
    fi

    if ! AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -er '.Credentials.SessionToken'); then
        echo "Failed to extract SessionToken from assume-role response"
        exit 1
    fi

    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN

    echo "Role assumed successfully"
    echo "   Account: $(aws sts get-caller-identity --query Account --output text)"
fi

ECS_CLUSTER_ARN=$(echo "$OUTPUTS" | jq -r '.ecs_cluster_arn.value')
TASK_DEFINITION_ARN=$(echo "$OUTPUTS" | jq -r '.ecs_task_definition_arn.value')
CLUSTER_NAME=$(echo "$OUTPUTS" | jq -r '.cluster_name.value')
PRIVATE_SUBNETS=$(echo "$OUTPUTS" | jq -r '.private_subnets.value[]' | tr '\n' ',' | sed 's/,$//')
BOOTSTRAP_SECURITY_GROUP=$(echo "$OUTPUTS" | jq -r '.bootstrap_security_group_id.value')
LOG_GROUP=$(echo "$OUTPUTS" | jq -r '.bootstrap_log_group_name.value')
REPOSITORY_URL=$(echo "$OUTPUTS" | jq -r '.repository_url.value')
REPOSITORY_BRANCH=$(echo "$OUTPUTS" | jq -r '.repository_branch.value')

# Static values
APPLICATIONSET_PATH="deploy/$ENVIRONMENT/$REGION_DEPLOYMENT/argocd-bootstrap-${CLUSTER_TYPE}"

# Extract cluster-type specific outputs
if [[ "$CLUSTER_TYPE" == "regional-cluster" ]]; then
    API_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.api_target_group_arn.value // ""')
    THANOS_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.thanos_target_group_arn.value // ""')
    THANOS_QUERY_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.thanos_query_target_group_arn.value // ""')
    LOKI_KMS_KEY_ARN=$(echo "$OUTPUTS" | jq -r '.loki_kms_key_arn.value // ""')
    LOKI_DISTRIBUTOR_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.loki_distributor_target_group_arn.value // ""')
    LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.loki_query_frontend_target_group_arn.value // ""')
else
    API_TARGET_GROUP_ARN=""
    THANOS_TARGET_GROUP_ARN=""
    THANOS_QUERY_TARGET_GROUP_ARN=""
    LOKI_KMS_KEY_ARN=""
    LOKI_DISTRIBUTOR_TARGET_GROUP_ARN=""
    LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN=""
fi

RHOBS_API_URL="${RHOBS_API_URL:-}"
DNS_ZONE_OPERATOR_ROLE_ARN="${DNS_ZONE_OPERATOR_ROLE_ARN:-}"

echo "Bootstrapping ArgoCD on cluster: $CLUSTER_NAME"

# Run ECS task
echo "Starting ECS task..."
# Capture output and exit code separately to handle errors properly with set -e
set +e
RUN_TASK_OUTPUT=$(aws ecs run-task \
  --cluster "$ECS_CLUSTER_ARN" \
  --task-definition "$TASK_DEFINITION_ARN" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNETS],securityGroups=[$BOOTSTRAP_SECURITY_GROUP],assignPublicIp=DISABLED}" \
  --overrides "{
    \"containerOverrides\": [{
      \"name\": \"bootstrap\",
      \"environment\": [
        {\"name\": \"CLUSTER_NAME\", \"value\": \"$CLUSTER_NAME\"},
        {\"name\": \"CLUSTER_TYPE\", \"value\": \"$CLUSTER_TYPE\"},
        {\"name\": \"REPOSITORY_URL\", \"value\": \"$REPOSITORY_URL\"},
        {\"name\": \"REPOSITORY_PATH\", \"value\": \"$APPLICATIONSET_PATH\"},
        {\"name\": \"REPOSITORY_BRANCH\", \"value\": \"$REPOSITORY_BRANCH\"},
        {\"name\": \"ENVIRONMENT\", \"value\": \"$ENVIRONMENT\"},
        {\"name\": \"AWS_REGION\", \"value\": \"$AWS_REGION\"},
        {\"name\": \"REGION_DEPLOYMENT\", \"value\": \"$REGION_DEPLOYMENT\"},
        {\"name\": \"CLUSTER_TYPE\", \"value\": \"$CLUSTER_TYPE\"},
        {\"name\": \"API_TARGET_GROUP_ARN\", \"value\": \"$API_TARGET_GROUP_ARN\"},
        {\"name\": \"THANOS_TARGET_GROUP_ARN\", \"value\": \"$THANOS_TARGET_GROUP_ARN\"},
        {\"name\": \"THANOS_QUERY_TARGET_GROUP_ARN\", \"value\": \"$THANOS_QUERY_TARGET_GROUP_ARN\"},
        {\"name\": \"LOKI_KMS_KEY_ARN\", \"value\": \"$LOKI_KMS_KEY_ARN\"},
        {\"name\": \"LOKI_DISTRIBUTOR_TARGET_GROUP_ARN\", \"value\": \"$LOKI_DISTRIBUTOR_TARGET_GROUP_ARN\"},
        {\"name\": \"LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN\", \"value\": \"$LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN\"},
        {\"name\": \"RHOBS_API_URL\", \"value\": \"$RHOBS_API_URL\"},
        {\"name\": \"DNS_ZONE_OPERATOR_ROLE_ARN\", \"value\": \"$DNS_ZONE_OPERATOR_ROLE_ARN\"}
      ]
    }]
  }" 2>&1)
RUN_TASK_EXIT_CODE=$?
set -e

# Check if run-task succeeded
if [[ $RUN_TASK_EXIT_CODE -eq 0 ]] && echo "$RUN_TASK_OUTPUT" | grep -q '"failures":\s*\[\]'; then
  echo "ECS task created successfully."
  TASK_ARN=$(echo "$RUN_TASK_OUTPUT" | jq -r '.task.taskArn // .tasks[0].taskArn // empty')
  if [[ -z "$TASK_ARN" || "$TASK_ARN" == "null" ]]; then
    echo "Could not extract task ARN from response"
    exit 1
  fi
  echo "Bootstrap task started: $TASK_ARN"
else
  echo "Failed to start ECS task. Error details:"
  echo "$RUN_TASK_OUTPUT"
  exit 1
fi

echo "Starting log monitoring..."

# Use filter-log-events for compatibility with older AWS CLI versions (no tail command)
# Track the last seen event timestamp to avoid duplicate logs
LAST_EVENT_TIME=0

# Clean up on script exit or interrupt
cleanup() {
    echo "" # Newline after log output
}
trap cleanup EXIT INT TERM

# Monitor task status
while true; do
    # Fetch recent log events (last 30 seconds worth)
    START_TIME=$(($(date +%s) * 1000 - 30000))
    if [[ $LAST_EVENT_TIME -gt 0 ]]; then
        START_TIME=$LAST_EVENT_TIME
    fi

    LOG_EVENTS=$(aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --start-time "$START_TIME" \
        --output json 2>/dev/null || echo '{"events":[]}')

    # Print new log events
    echo "$LOG_EVENTS" | jq -r '.events[] | .message' 2>/dev/null || true

    # Update last event timestamp (add 1 to exclude already-seen events on next poll)
    NEW_LAST_TIME=$(echo "$LOG_EVENTS" | jq -r '[.events[].timestamp] | max // 0' 2>/dev/null || echo "0")
    if [[ "$NEW_LAST_TIME" != "null" && "$NEW_LAST_TIME" != "0" ]]; then
        LAST_EVENT_TIME=$((NEW_LAST_TIME + 1))
    fi

    TASK_STATUS=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER_ARN" --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text)

    if [[ "$TASK_STATUS" == "STOPPED" ]]; then
        # Fetch any remaining logs after task stopped
        sleep 2
        FINAL_LOGS=$(aws logs filter-log-events \
            --log-group-name "$LOG_GROUP" \
            --start-time "$LAST_EVENT_TIME" \
            --output json 2>/dev/null || echo '{"events":[]}')
        echo "$FINAL_LOGS" | jq -r '.events[] | .message' 2>/dev/null || true
        echo ""
        echo "Task stopped. Getting task details..."

        # Get full task details for debugging
        TASK_DETAILS=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER_ARN" --tasks "$TASK_ARN")

        # Extract exit code and stop reason
        EXIT_CODE=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containers[0].exitCode // "null"')
        STOP_REASON=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].stopReason // "unknown"')
        CONTAINER_REASON=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containers[0].reason // "unknown"')

        if [[ "$EXIT_CODE" == "0" ]]; then
            echo "Bootstrap completed successfully!"
            exit 0
        elif [[ "$EXIT_CODE" == "null" || -z "$EXIT_CODE" ]]; then
            echo "Bootstrap failed - no exit code available"
            echo ""
            echo "Task Stop Reason: $STOP_REASON"
            echo "Container Reason: $CONTAINER_REASON"
            echo ""
            echo "Full task details:"
            echo "$TASK_DETAILS" | jq '.tasks[0] | {lastStatus, stoppedReason: .stoppedReason, stopCode: .stopCode, containers: [.containers[] | {name, exitCode, reason, lastStatus}]}'
            exit 1
        else
            echo "Bootstrap failed with exit code: $EXIT_CODE"
            echo ""
            echo "Task Stop Reason: $STOP_REASON"
            echo "Container Reason: $CONTAINER_REASON"
            exit 1
        fi
    fi

    # Poll every 5 seconds for log updates
    sleep 5
done
