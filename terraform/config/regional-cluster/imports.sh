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
