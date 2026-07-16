#!/usr/bin/env bash
#
# imports.sh - Idempotent Terraform imports for Regional Cluster
#
# Adopts AWS-auto-created CloudWatch log groups into Terraform state so that
# aws_cloudwatch_log_group resources can manage retention + KMS going forward.
#
# Safe to run on any environment:
#   - Fresh env: imports are skipped (resources don't exist yet), TF creates them
#   - Existing env: imports succeed, TF updates retention/KMS in-place
#   - Subsequent runs: all resources already in state, all skipped (~10ms each)
#
# Required env vars: TF_VAR_regional_id
#
# Once all environments have been migrated, this file can be removed.
set -uo pipefail

# import_if_needed, tf_state_value, tf_import_summary provided by lib.sh
# (sourced by the parent buildspec script)

echo "--- Importing existing CloudWatch log groups (Regional Cluster) ---"

# =============================================================================
# Static imports — IDs are deterministic from environment variables
# =============================================================================

import_if_needed \
    'module.maestro_infrastructure.aws_cloudwatch_log_group.rds_postgresql' \
    "/aws/rds/instance/${TF_VAR_regional_id}-maestro/postgresql"

import_if_needed \
    'module.maestro_infrastructure.aws_cloudwatch_log_group.rds_upgrade' \
    "/aws/rds/instance/${TF_VAR_regional_id}-maestro/upgrade"

import_if_needed \
    'module.maestro_infrastructure.aws_cloudwatch_log_group.iot_core' \
    "AWSIotLogsV2"

import_if_needed \
    'module.hyperfleet_infrastructure.aws_cloudwatch_log_group.rds_postgresql' \
    "/aws/rds/instance/${TF_VAR_regional_id}-hyperfleet/postgresql"

import_if_needed \
    'module.hyperfleet_infrastructure.aws_cloudwatch_log_group.rds_upgrade' \
    "/aws/rds/instance/${TF_VAR_regional_id}-hyperfleet/upgrade"

# =============================================================================
# Dynamic imports — IDs depend on resources already in state
# =============================================================================

BROKER_ID=$(tf_state_value \
    'module.hyperfleet_infrastructure.aws_mq_broker.hyperfleet' '.values.id')
echo "  [debug] BROKER_ID=${BROKER_ID:-<empty>}"
if [ -n "$BROKER_ID" ]; then
    # The MQ log group names embed the broker UUID, so they can only be created
    # after the broker exists. On the first apply after broker creation the log
    # groups may not exist in AWS yet — in that case skip the import and let
    # Terraform create them. Use an explicit AWS CLI check rather than relying
    # on Terraform's error-message pattern matching for this resource type.
    _MQ_GENERAL="/aws/amazonmq/broker/${BROKER_ID}/general"
    _MQ_CONNECTION="/aws/amazonmq/broker/${BROKER_ID}/connection"

    _GENERAL_EXISTS=$(aws logs describe-log-groups \
        --log-group-name-prefix "$_MQ_GENERAL" \
        --query "logGroups[?logGroupName=='${_MQ_GENERAL}'] | length(@)" \
        --output text 2>/dev/null || echo 0)
    if [ "${_GENERAL_EXISTS:-0}" -ge 1 ]; then
        import_if_needed \
            'module.hyperfleet_infrastructure.aws_cloudwatch_log_group.mq_general' \
            "$_MQ_GENERAL"
    else
        echo "  [skip] AmazonMQ general log group — not yet in AWS"
    fi

    _CONNECTION_EXISTS=$(aws logs describe-log-groups \
        --log-group-name-prefix "$_MQ_CONNECTION" \
        --query "logGroups[?logGroupName=='${_MQ_CONNECTION}'] | length(@)" \
        --output text 2>/dev/null || echo 0)
    if [ "${_CONNECTION_EXISTS:-0}" -ge 1 ]; then
        import_if_needed \
            'module.hyperfleet_infrastructure.aws_cloudwatch_log_group.mq_connection' \
            "$_MQ_CONNECTION"
    else
        echo "  [skip] AmazonMQ connection log group — not yet in AWS"
    fi
else
    echo "  [skip] AmazonMQ log groups — broker not yet provisioned"
fi

import_if_needed \
    'module.rhobs_api_gateway.aws_cloudwatch_log_group.api_gateway_access' \
    "/aws/api-gateway/${TF_VAR_regional_id}-rhobs/${TF_VAR_stage_name:-prod}/access"


API_ID=$(tf_state_value \
    'module.api_gateway.aws_api_gateway_rest_api.main' '.values.id')
STAGE_NAME=$(tf_state_value \
    'module.api_gateway.aws_api_gateway_stage.main' '.values.stage_name')
STAGE_NAME="${STAGE_NAME:-prod}"
echo "  [debug] API_ID=${API_ID:-<empty>} STAGE_NAME=${STAGE_NAME}"
if [ -n "$API_ID" ]; then
    import_if_needed \
        'module.api_gateway.aws_cloudwatch_log_group.api_gateway_execution' \
        "API-Gateway-Execution-Logs_${API_ID}/${STAGE_NAME}"
else
    echo "  [skip] API GW execution log group — API not yet provisioned"
fi

tf_import_summary
