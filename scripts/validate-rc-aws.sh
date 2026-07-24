#!/usr/bin/env bash
# Validate AWS-level configuration and resources for the Regional Cluster (RC).
#
# Usage:
#   ./scripts/validate-rc-aws.sh                          # auto-derives CLUSTER_ID and AWS_REGION from kubectl context
#   CLUSTER_ID=<id> AWS_REGION=<region> ./scripts/validate-rc-aws.sh   # override if needed
#
# Optional:
#   PLATFORM_API_TG_ARN=<arn>  — ALB target group ARN for the platform-api service.
#                                 If unset, the target-health check is skipped.
#
# Prerequisites: aws CLI configured with appropriate credentials for the RC account.

set -euo pipefail

# Auto-derive CLUSTER_ID and AWS_REGION from the active kubectl context when not set explicitly.
# aws eks update-kubeconfig names contexts: arn:aws:eks:<region>:<account>:cluster/<name>
_ctx=$(kubectl config current-context 2>/dev/null || true)
if [[ -z "${CLUSTER_ID:-}" && "$_ctx" =~ :cluster/(.+)$ ]]; then
    CLUSTER_ID="${BASH_REMATCH[1]}"
fi
if [[ -z "${AWS_REGION:-}" && "$_ctx" =~ arn:aws:eks:([^:]+): ]]; then
    AWS_REGION="${BASH_REMATCH[1]}"
fi
CLUSTER_ID="${CLUSTER_ID:?Cannot derive CLUSTER_ID — set it manually or ensure the active kubectl context points at an EKS cluster}"
AWS_REGION="${AWS_REGION:?Cannot derive AWS_REGION — set it manually or ensure the active kubectl context points at an EKS cluster}"
PLATFORM_API_TG_ARN="${PLATFORM_API_TG_ARN:-}"

export AWS_DEFAULT_REGION="$AWS_REGION"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; ((++PASS)); }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; ((++FAIL)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; ((++WARN)); }

section() { echo; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# 1. EKS cluster
# ---------------------------------------------------------------------------

section "EKS cluster"

cluster_status=$(aws eks describe-cluster \
    --name "$CLUSTER_ID" \
    --query "cluster.status" \
    --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$cluster_status" == "ACTIVE" ]]; then
    pass "EKS cluster '${CLUSTER_ID}' ACTIVE"
else
    fail "EKS cluster '${CLUSTER_ID}' status: ${cluster_status}"
fi

# Verify auth mode is API_AND_CONFIG_MAP (required for Karpenter node access entries)
auth_mode=$(aws eks describe-cluster \
    --name "$CLUSTER_ID" \
    --query "cluster.accessConfig.authenticationMode" \
    --output text 2>/dev/null || echo "UNKNOWN")
if [[ "$auth_mode" == "API_AND_CONFIG_MAP" ]]; then
    pass "EKS auth mode: API_AND_CONFIG_MAP"
else
    fail "EKS auth mode: ${auth_mode} (expected API_AND_CONFIG_MAP)"
fi

# ---------------------------------------------------------------------------
# 2. EKS managed add-ons
# ---------------------------------------------------------------------------

section "EKS managed add-ons"

EXPECTED_ADDONS=(
    "coredns"
    "metrics-server"
    "eks-pod-identity-agent"
    "vpc-cni"
    "kube-proxy"
    "aws-ebs-csi-driver"
    "aws-secrets-store-csi-driver-provider"
)

addon_json=$(aws eks list-addons \
    --cluster-name "$CLUSTER_ID" \
    --output json 2>/dev/null | jq -r '.addons[]')

for addon in "${EXPECTED_ADDONS[@]}"; do
    if echo "$addon_json" | grep -q "^${addon}$"; then
        status=$(aws eks describe-addon \
            --cluster-name "$CLUSTER_ID" \
            --addon-name "$addon" \
            --query "addon.status" \
            --output text 2>/dev/null || echo "UNKNOWN")
        if [[ "$status" == "ACTIVE" ]]; then
            pass "Add-on ${addon}: ACTIVE"
        else
            fail "Add-on ${addon}: ${status}"
        fi
    else
        warn "Add-on ${addon}: not installed"
    fi
done

# ---------------------------------------------------------------------------
# 3. Karpenter bootstrap node group
# ---------------------------------------------------------------------------

section "Karpenter bootstrap node group"

ng_name="${CLUSTER_ID}-karpenter-bootstrap"

ng_status=$(aws eks describe-nodegroup \
    --cluster-name "$CLUSTER_ID" \
    --nodegroup-name "$ng_name" \
    --query "nodegroup.status" \
    --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$ng_status" == "ACTIVE" ]]; then
    pass "Node group '${ng_name}': ACTIVE"
else
    fail "Node group '${ng_name}': ${ng_status}"
fi

ng_desired=$(aws eks describe-nodegroup \
    --cluster-name "$CLUSTER_ID" \
    --nodegroup-name "$ng_name" \
    --query "nodegroup.scalingConfig.desiredSize" \
    --output text 2>/dev/null || echo "0")

ng_ready=$(aws eks describe-nodegroup \
    --cluster-name "$CLUSTER_ID" \
    --nodegroup-name "$ng_name" \
    --query "nodegroup.health.issues" \
    --output json 2>/dev/null | jq 'length')

if [[ "$ng_ready" -eq 0 ]]; then
    pass "Node group '${ng_name}': ${ng_desired} nodes, no health issues"
else
    fail "Node group '${ng_name}': ${ng_ready} health issue(s)"
fi

# ---------------------------------------------------------------------------
# 4. IAM roles
# ---------------------------------------------------------------------------

section "IAM roles"

declare -A IAM_ROLES=(
    ["karpenter-controller"]="${CLUSTER_ID}-karpenter-controller"
    ["karpenter-node"]="${CLUSTER_ID}-karpenter-node-role"
    ["aws-load-balancer-controller"]="${CLUSTER_ID}-aws-load-balancer-controller"
    ["eks-cluster"]="${CLUSTER_ID}-cluster-role"
    ["ebs-csi"]="${CLUSTER_ID}-ebs-csi-role"
)

for label in "${!IAM_ROLES[@]}"; do
    role_name="${IAM_ROLES[$label]}"
    if aws iam get-role --role-name "$role_name" &>/dev/null; then
        pass "IAM role exists: ${role_name}"
    else
        fail "IAM role missing: ${role_name}"
    fi
done

# ---------------------------------------------------------------------------
# 5. SQS queue (Karpenter interruption handling)
# ---------------------------------------------------------------------------

section "SQS queue"

queue_name="${CLUSTER_ID}-karpenter"

if aws sqs get-queue-url --queue-name "$queue_name" &>/dev/null; then
    pass "SQS queue '${queue_name}' exists"
else
    fail "SQS queue '${queue_name}' not found"
fi

# ---------------------------------------------------------------------------
# 6. Karpenter-tagged EC2 instances
# ---------------------------------------------------------------------------

section "Karpenter EC2 instances"

kp_instance_count=$(aws ec2 describe-instances \
    --filters \
        "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_ID}" \
        "Name=instance-state-name,Values=running" \
    --query "length(Reservations[*].Instances[])" \
    --output text 2>/dev/null || echo 0)

if [[ "$kp_instance_count" -ge 1 ]]; then
    pass "Karpenter-provisioned EC2 instances running: ${kp_instance_count}"
else
    warn "No running EC2 instances tagged karpenter.sh/discovery=${CLUSTER_ID}"
fi

# ---------------------------------------------------------------------------
# 7. ALB target health (platform-api)
# ---------------------------------------------------------------------------

section "ALB target health"

if [[ -n "$PLATFORM_API_TG_ARN" ]]; then
    healthy=$(aws elbv2 describe-target-health \
        --target-group-arn "$PLATFORM_API_TG_ARN" \
        --query "TargetHealthDescriptions[?TargetHealth.State=='healthy'] | length(@)" \
        --output text 2>/dev/null || echo 0)
    unhealthy=$(aws elbv2 describe-target-health \
        --target-group-arn "$PLATFORM_API_TG_ARN" \
        --query "TargetHealthDescriptions[?TargetHealth.State!='healthy'] | length(@)" \
        --output text 2>/dev/null || echo 0)
    if [[ "$healthy" -ge 1 ]]; then
        pass "Platform API target group: ${healthy} healthy target(s), ${unhealthy} unhealthy"
    else
        fail "Platform API target group: 0 healthy targets (${unhealthy} unhealthy)"
    fi
else
    warn "PLATFORM_API_TG_ARN not set — skipping target health check"
    warn "  Set it to: kubectl get svc -n platform-api -o jsonpath='{.items[0].metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-arn}'"
fi

# ---------------------------------------------------------------------------
# 8. ECS bootstrap cluster
# ---------------------------------------------------------------------------

section "ECS bootstrap cluster"

ecs_cluster_name="${CLUSTER_ID}-bootstrap"

ecs_status=$(aws ecs describe-clusters \
    --clusters "$ecs_cluster_name" \
    --query "clusters[0].status" \
    --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$ecs_status" == "ACTIVE" ]]; then
    pass "ECS cluster '${ecs_cluster_name}' ACTIVE"
else
    fail "ECS cluster '${ecs_cluster_name}' status: ${ecs_status}"
fi

# ---------------------------------------------------------------------------
# 9. CloudWatch log group
# ---------------------------------------------------------------------------

section "CloudWatch log group"

log_group="/aws/eks/${CLUSTER_ID}/cluster"

if aws logs describe-log-groups \
    --log-group-name-prefix "$log_group" \
    --query "logGroups[?logGroupName=='${log_group}'] | length(@)" \
    --output text 2>/dev/null | grep -q "^[1-9]"; then
    pass "CloudWatch log group '${log_group}' exists"
else
    fail "CloudWatch log group '${log_group}' not found"
fi

# ---------------------------------------------------------------------------
# 10. KMS key aliases
# ---------------------------------------------------------------------------

section "KMS key aliases"

declare -A KMS_ALIASES=(
    ["cloudwatch-logs"]="alias/${CLUSTER_ID}-cloudwatch-logs"
    ["eks-secrets"]="alias/${CLUSTER_ID}-eks-secrets"
)

for label in "${!KMS_ALIASES[@]}"; do
    alias_name="${KMS_ALIASES[$label]}"
    if aws kms list-aliases \
        --query "Aliases[?AliasName=='${alias_name}'] | length(@)" \
        --output text 2>/dev/null | grep -q "^[1-9]"; then
        pass "KMS alias '${alias_name}' (${label}) exists"
    else
        fail "KMS alias '${alias_name}' (${label}) not found"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

section "Summary"
echo -e "  ${GREEN}PASS${RESET}: ${PASS}  ${RED}FAIL${RESET}: ${FAIL}  ${YELLOW}WARN${RESET}: ${WARN}"

[[ "$FAIL" -eq 0 ]]
