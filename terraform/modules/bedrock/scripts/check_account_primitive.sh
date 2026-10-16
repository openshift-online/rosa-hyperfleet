#!/usr/bin/env bash
# Plan-time probe for AWS account-scoped Bedrock/Budget primitives.
# Used by data.external in this module to skip create when the object already
# exists in AWS (shared ephemeral/CI pool accounts). Skipped resources are NOT
# added to Terraform state — cluster stack destroy does not remove them.
set -euo pipefail

for cmd in aws jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "{\"exists\":\"false\"}"
    exit 0
  fi
done

query="$(cat)"
check="$(echo "$query" | jq -r '.check')"

exists="false"

case "$check" in
  agreement)
    model_id="$(echo "$query" | jq -r '.model_id')"
    region="$(echo "$query" | jq -r '.region')"
    status="$(aws bedrock get-foundation-model-availability \
      --model-id "$model_id" \
      --region "$region" \
      --query 'agreementAvailability.status' \
      --output text 2>/dev/null || echo "NOT_AVAILABLE")"
    if [ "$status" = "AVAILABLE" ] || [ "$status" = "PENDING" ]; then
      exists="true"
    fi
    ;;
  budget)
    account_id="$(echo "$query" | jq -r '.account_id')"
    budget_name="$(echo "$query" | jq -r '.budget_name')"
    if aws budgets describe-budget \
      --account-id "$account_id" \
      --budget-name "$budget_name" \
      --region us-east-1 >/dev/null 2>&1; then
      exists="true"
    fi
    ;;
  *)
    echo "unknown check: $check" >&2
    exit 1
    ;;
esac

jq -n --arg exists "$exists" '{exists:$exists}'
