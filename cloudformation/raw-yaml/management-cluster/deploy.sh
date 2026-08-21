#!/usr/bin/env bash
#
# deploy.sh — Package and deploy MC CloudFormation templates.
#
# Uploads nested templates to S3 (required for AWS::CloudFormation::Stack),
# then creates or updates the root stack.
#
# Usage:
#   ./deploy.sh <stack-name> <s3-bucket> [--params-file params.json]
#
# Example:
#   ./deploy.sh mc01 hyperfleet-cf-templates --params-file mc01-params.json
#
# This script exists because CF nested stacks require template hosting in S3.
# With Terraform, you just run "terraform apply" — no upload step needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STACK_NAME="${1:?Usage: $0 <stack-name> <s3-bucket> [--params-file params.json]}"
S3_BUCKET="${2:?Usage: $0 <stack-name> <s3-bucket> [--params-file params.json]}"
PARAMS_FILE=""

shift 2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --params-file)
            PARAMS_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

VERSION="$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "dev")"
S3_PREFIX="management-cluster/${VERSION}"
S3_URL="https://${S3_BUCKET}.s3.amazonaws.com/${S3_PREFIX}"

TEMPLATES=(
    vpc.yaml
    eks-cluster.yaml
    ecs-bootstrap.yaml
    bastion.yaml
    dns-pod-identity.yaml
    hypershift-oidc.yaml
    prometheus-remote-write.yaml
    loki-log-forwarder.yaml
    cloudwatch-exporter.yaml
    kube-applier.yaml
    zoa-job-pod-identity.yaml
    grafana-cloudwatch-logs.yaml
)

echo "=== Validating templates ==="
for tpl in root.yaml "${TEMPLATES[@]}"; do
    echo "  Validating ${tpl}..."
    aws cloudformation validate-template \
        --template-body "file://${SCRIPT_DIR}/${tpl}" \
        --output text > /dev/null
done
echo "  All templates valid."

echo ""
echo "=== Uploading nested templates to s3://${S3_BUCKET}/${S3_PREFIX}/ ==="
for tpl in "${TEMPLATES[@]}"; do
    aws s3 cp "${SCRIPT_DIR}/${tpl}" "s3://${S3_BUCKET}/${S3_PREFIX}/${tpl}" --quiet
    echo "  Uploaded ${tpl}"
done
echo "  Done."

echo ""
echo "=== Deploying root stack: ${STACK_NAME} ==="

DEPLOY_ARGS=(
    --stack-name "${STACK_NAME}"
    --template-body "file://${SCRIPT_DIR}/root.yaml"
    --capabilities CAPABILITY_NAMED_IAM
    --parameters "ParameterKey=TemplatesBucketUrl,ParameterValue=${S3_URL}"
)

if [[ -n "${PARAMS_FILE}" ]]; then
    DEPLOY_ARGS+=(--parameters "file://${PARAMS_FILE}")
fi

if aws cloudformation describe-stacks --stack-name "${STACK_NAME}" &>/dev/null; then
    echo "  Stack exists — updating..."
    aws cloudformation update-stack "${DEPLOY_ARGS[@]}" || {
        echo "  No updates to perform (stack is already up to date)."
    }
else
    echo "  Creating new stack..."
    aws cloudformation create-stack "${DEPLOY_ARGS[@]}"
fi

echo ""
echo "=== Waiting for stack operation to complete ==="
aws cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" 2>/dev/null ||
    aws cloudformation wait stack-update-complete --stack-name "${STACK_NAME}" 2>/dev/null ||
    echo "  Stack operation may still be in progress — check the AWS console."

echo ""
echo "=== Stack outputs ==="
aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query 'Stacks[0].Outputs' --output table
