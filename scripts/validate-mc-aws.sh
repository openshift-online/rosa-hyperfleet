#!/usr/bin/env bash
# Validate AWS-level configuration and resources for a Management Cluster (MC).
#
# Usage:
#   ./scripts/validate-mc-aws.sh                          # auto-derives CLUSTER_ID and AWS_REGION from kubectl context
#   CLUSTER_ID=<id> AWS_REGION=<region> ./scripts/validate-mc-aws.sh   # override if needed
#
# Prerequisites: aws CLI configured with appropriate credentials for the MC account.

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

cluster_version=$(aws eks describe-cluster \
    --name "$CLUSTER_ID" \
    --query "cluster.version" \
    --output text 2>/dev/null || echo "unknown")
pass "EKS cluster version: ${cluster_version}"

auth_mode=$(aws eks describe-cluster \
    --name "$CLUSTER_ID" \
    --query "cluster.accessConfig.authenticationMode" \
    --output text 2>/dev/null || echo "UNKNOWN")
if [[ "$auth_mode" == "API_AND_CONFIG_MAP" ]]; then
    pass "EKS auth mode: API_AND_CONFIG_MAP"
else
    fail "EKS auth mode: ${auth_mode} (expected API_AND_CONFIG_MAP)"
fi

# Private endpoint required — no public access
public_access=$(aws eks describe-cluster \
    --name "$CLUSTER_ID" \
    --query "cluster.resourcesVpcConfig.endpointPublicAccess" \
    --output text 2>/dev/null || echo "unknown")
if [[ "$public_access" == "False" ]]; then
    pass "EKS public endpoint access: disabled"
else
    fail "EKS public endpoint access: ${public_access} (must be False)"
fi

# ---------------------------------------------------------------------------
# 2. EKS managed add-ons
# ---------------------------------------------------------------------------

section "EKS managed add-ons"

EXPECTED_ADDONS=(
    "coredns"
    "vpc-cni"
    "kube-proxy"
    "eks-pod-identity-agent"
    "aws-ebs-csi-driver"
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
    ng_desired=$(aws eks describe-nodegroup \
        --cluster-name "$CLUSTER_ID" \
        --nodegroup-name "$ng_name" \
        --query "nodegroup.scalingConfig.desiredSize" \
        --output text 2>/dev/null || echo "?")
    pass "Node group '${ng_name}': ACTIVE (desired: ${ng_desired})"
else
    fail "Node group '${ng_name}': ${ng_status}"
fi

# ---------------------------------------------------------------------------
# 4. EC2 instances (Karpenter-provisioned)
# ---------------------------------------------------------------------------

section "EC2 instances"

kp_instance_count=$(aws ec2 describe-instances \
    --filters \
        "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_ID}" \
        "Name=instance-state-name,Values=running" \
    --query "length(Reservations[*].Instances[])" \
    --output text 2>/dev/null || echo 0)

if [[ "$kp_instance_count" -ge 1 ]]; then
    pass "Karpenter-provisioned EC2 instances running: ${kp_instance_count}"
else
    warn "No running EC2 instances tagged karpenter.sh/discovery=${CLUSTER_ID} (expected once workloads are scheduled)"
fi

# Confirm all running cluster instances are in the right VPC
cluster_vpc=$(aws eks describe-cluster \
    --name "$CLUSTER_ID" \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text 2>/dev/null || echo "")

if [[ -n "$cluster_vpc" ]]; then
    wrong_vpc=$(aws ec2 describe-instances \
        --filters \
            "Name=tag:kubernetes.io/cluster/${CLUSTER_ID},Values=owned" \
            "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[?VpcId!='${cluster_vpc}'] | length(@)" \
        --output text 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
    if [[ "$wrong_vpc" -eq 0 ]]; then
        pass "All cluster EC2 instances in correct VPC (${cluster_vpc})"
    else
        fail "${wrong_vpc} cluster EC2 instance(s) in unexpected VPC"
    fi
fi

# ---------------------------------------------------------------------------
# 5. IAM roles
# ---------------------------------------------------------------------------

section "IAM roles"

declare -A IAM_ROLES=(
    ["karpenter-controller"]="${CLUSTER_ID}-karpenter-controller"
    ["karpenter-node"]="${CLUSTER_ID}-karpenter-node-role"
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

# HyperShift installs a service account that needs a role — check it exists if HC is running
hs_role="${CLUSTER_ID}-hypershift-operator"
if aws iam get-role --role-name "$hs_role" &>/dev/null; then
    pass "IAM role exists: ${hs_role}"
else
    warn "IAM role '${hs_role}' not found (expected if HyperShift installed via IRSA)"
fi

# ---------------------------------------------------------------------------
# 6. SQS queue (Karpenter interruption handling)
# ---------------------------------------------------------------------------

section "SQS queue"

queue_name="${CLUSTER_ID}-karpenter"

if aws sqs get-queue-url --queue-name "$queue_name" &>/dev/null; then
    pass "SQS queue '${queue_name}' exists"
else
    fail "SQS queue '${queue_name}' not found"
fi

# ---------------------------------------------------------------------------
# 7. ECS bootstrap cluster
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
# 8. CloudWatch log group
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
# 9. VPC and subnet availability
# ---------------------------------------------------------------------------

section "VPC and subnets"

vpc_id=$(aws eks describe-cluster \
    --name "$CLUSTER_ID" \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text 2>/dev/null || echo "")

if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    fail "Could not retrieve VPC ID for cluster '${CLUSTER_ID}'"
else
    vpc_state=$(aws ec2 describe-vpcs \
        --vpc-ids "$vpc_id" \
        --query "Vpcs[0].State" \
        --output text 2>/dev/null || echo "not-found")
    if [[ "$vpc_state" == "available" ]]; then
        pass "VPC ${vpc_id} state: available"
    else
        fail "VPC ${vpc_id} state: ${vpc_state}"
    fi

    # Each private subnet should have available IPs
    subnet_ids=$(aws eks describe-cluster \
        --name "$CLUSTER_ID" \
        --query "cluster.resourcesVpcConfig.subnetIds[]" \
        --output text 2>/dev/null || echo "")

    no_ips=0
    total_subnets=0
    for subnet in $subnet_ids; do
        ((total_subnets++))
        available_ips=$(aws ec2 describe-subnets \
            --subnet-ids "$subnet" \
            --query "Subnets[0].AvailableIpAddressCount" \
            --output text 2>/dev/null || echo 0)
        if [[ "$available_ips" -lt 5 ]]; then
            ((no_ips++))
            warn "Subnet ${subnet}: only ${available_ips} available IPs"
        fi
    done
    if [[ "$no_ips" -eq 0 ]]; then
        pass "All ${total_subnets} subnets have adequate available IPs"
    else
        fail "${no_ips}/${total_subnets} subnet(s) with fewer than 5 available IPs"
    fi
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
