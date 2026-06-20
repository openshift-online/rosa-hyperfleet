#!/usr/bin/env bash
#
# init-terraform-backend.sh - Initialize Terraform with target account backend
#
# This script handles Terraform backend initialization for pipelines.
# State is stored in the target account's S3 bucket (the account where
# resources reside). The caller must have already assumed credentials
# for the target account (e.g., via use_mc_account or use_rc_account).
#
# Usage: init-terraform-backend.sh <cluster-type> <region> <cluster-id>
#   cluster-type: regional-cluster, management-cluster, or maestro-agent-iot
#   region: AWS region for the cluster
#   cluster-id: Cluster identifier for state key (regional_id or management_id)
#
# Expected environment variables:
#   Ambient AWS credentials for the target account (via account-helpers.sh)

set -euo pipefail

# Validate arguments
if [ $# -ne 3 ]; then
    echo "ERROR: init-terraform-backend.sh requires exactly 3 arguments"
    echo "Usage: init-terraform-backend.sh <cluster-type> <region> <cluster-id>"
    echo "  cluster-type: regional-cluster or management-cluster"
    echo "  region: AWS region for the cluster"
    echo "  cluster-id: Cluster identifier for state key (regional_id or management_id)"
    exit 1
fi

CLUSTER_TYPE=$1
REGION=$2
CLUSTER_ID=$3

# Detect state bucket from the current (target) account
TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${REGION}"

# Configure Terraform region via environment variable
export TF_VAR_region="${REGION}"

# Set state key based on cluster type
export TF_STATE_KEY="${CLUSTER_TYPE}/${CLUSTER_ID}.tfstate"

echo "Terraform backend configuration:"
echo "  Bucket: $TF_STATE_BUCKET (account: $TARGET_ACCOUNT_ID)"
echo "  Key: $TF_STATE_KEY"
echo "  Region: $REGION"
echo ""

# Initialize Terraform with backend configuration
echo "Initializing Terraform..."
(
    cd "terraform/config/${CLUSTER_TYPE}"
    terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${TF_STATE_KEY}" \
        -backend-config="region=${REGION}" \
        -backend-config="use_lockfile=true" \
        -backend-config="use_fips_endpoint=false"
)

echo "Terraform backend initialized successfully"

# Verify terraform outputs are available
echo "Checking terraform outputs are available..."
(
    cd "terraform/config/${CLUSTER_TYPE}"
    if ! terraform output -json > /tmp/tf-outputs.json 2>&1; then
        echo "Failed to read terraform outputs"
        cat /tmp/tf-outputs.json
        exit 1
    fi
    if [ "$(jq 'length' /tmp/tf-outputs.json)" -eq 0 ]; then
        echo "ERROR: No terraform outputs found — terraform apply may not have run for this cluster."
        exit 1
    fi
    echo "Terraform outputs available:"
    jq 'keys' /tmp/tf-outputs.json
)
