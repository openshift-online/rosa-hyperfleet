#!/usr/bin/env bash
#
# Bootstrap the LocalStack environment to emulate the ROSA HyperFleet
# multi-account AWS setup.
#
# This script is mounted into the LocalStack container and runs automatically
# via the ready.d hook. It can also be run manually:
#   docker exec rosa-hyperfleet-localstack /etc/localstack/init/ready.d/init-aws.sh
#
# The mock resources created here mirror the real infrastructure that the
# ephemeral-provision flow expects to find in AWS.

# =============================================================================
# Debugging & Error Handling
# =============================================================================

# Enable bash trace debugging when DEBUG_INIT=1 is set.
# Usage: DEBUG_INIT=1 make localstack-provision
if [[ "${DEBUG_INIT:-0}" == "1" ]]; then
    set -x
fi

# Catch unset variables (-u) and broken pipes (-o pipefail).
# Propagate the ERR trap into functions and subshells (-E).
#
# We intentionally omit -e so that a single failed command does NOT silently
# abort the entire script.  Instead every awslocal call is wrapped with
# explicit error handling that logs the full command, stderr, and exit code.
set -Euo pipefail

# Safety-net trap: fires on any unguarded non-zero exit (commands not already
# inside an if / || / && guard).  Prints the exact source file and line.
trap 'echo ">>> ERR trap: ${BASH_SOURCE[0]:-$0} line ${LINENO}, exit code $?" >&2' ERR

# Disable the AWS CLI pager globally (works with both CLI v1 and v2).
export AWS_PAGER=""

# ---------------------------------------------------------------------------
# log MESSAGE…
#   Print a timestamped message.
# ---------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '???')] $*"
}

# ---------------------------------------------------------------------------
# run_aws DESC CMD [ARGS…]
#   Execute a command, capture stderr to a temp file, and on failure log the
#   full command line, exit code, and stderr contents.  Returns the command's
#   exit code so the caller can decide whether to continue or abort.
# ---------------------------------------------------------------------------
run_aws() {
    local desc="$1"; shift
    local stderr_file
    stderr_file=$(mktemp /tmp/init-aws-err.XXXXXX)

    local rc=0
    "$@" 2>"${stderr_file}" || rc=$?
    if (( rc == 0 )); then
        rm -f "${stderr_file}"
        return 0
    fi
    log "FAILED [exit ${rc}]: ${desc}"
    log "  command: $*"
    if [ -s "${stderr_file}" ]; then
        log "  stderr:"
        sed 's/^/    /' "${stderr_file}" >&2
    fi
    rm -f "${stderr_file}"
    return "${rc}"
}

# ---------------------------------------------------------------------------
# run_aws_capture DESC CMD [ARGS…]
#   Like run_aws but captures stdout for variable assignment.  Prints the
#   captured stdout on success; prints nothing to stdout on failure.
#   Usage:  VAR=$(run_aws_capture "desc" cmd args…) || true
# ---------------------------------------------------------------------------
run_aws_capture() {
    local desc="$1"; shift
    local stderr_file stdout_result
    stderr_file=$(mktemp /tmp/init-aws-err.XXXXXX)

    local rc=0
    stdout_result=$("$@" 2>"${stderr_file}") || rc=$?
    if (( rc == 0 )); then
        rm -f "${stderr_file}"
        printf '%s' "${stdout_result}"
        return 0
    fi
    log "FAILED [exit ${rc}]: ${desc}"
    log "  command: $*"
    if [ -s "${stderr_file}" ]; then
        log "  stderr:"
        sed 's/^/    /' "${stderr_file}" >&2
    fi
    rm -f "${stderr_file}"
    return "${rc}"
}

# =============================================================================
# Configuration
# =============================================================================

AWS_REGION="us-east-1"
ENVIRONMENT="localstack"
DOMAIN="localstack.rosa.local"

# Mock account IDs (12-digit, matching config/localstack/defaults.yaml)
CENTRAL_ACCOUNT="000000000001"
RC_ACCOUNT="000000000002"
MC_ACCOUNT="000000000003"
CUSTOMER_ACCOUNT="000000000004"

# awslocal is pre-installed in the LocalStack container
AWSLOCAL="awslocal"

# =============================================================================
# Helpers — service readiness and retry logic
# =============================================================================

# Wait for a LocalStack service to become ready before using it.
# Retries the given awslocal command until it succeeds (max 30s).
wait_for_service() {
    local service_name="$1"
    shift
    local max_wait=30
    local elapsed=0
    while ! "$@" >/dev/null 2>&1; do
        if (( elapsed >= max_wait )); then
            log "  WARNING: ${service_name} not ready after ${max_wait}s, proceeding anyway"
            return 0
        fi
        sleep 2
        (( elapsed += 2 )) || true
    done
}

# Retry a command up to N times with a delay between attempts.
# Usage: retry <max_attempts> <delay_seconds> <command...>
retry() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1
    local rc=0
    while true; do
        rc=0
        "$@" || rc=$?
        if (( rc == 0 )); then
            return 0
        fi
        if (( attempt >= max_attempts )); then
            log "    FAILED after ${max_attempts} attempts (last exit=${rc}): $*"
            return 1
        fi
        sleep "${delay}"
        (( attempt++ )) || true
    done
}

log "============================================================"
log "  ROSA HyperFleet — LocalStack Bootstrap"
log "============================================================"
log ""
log "  Region:           ${AWS_REGION}"
log "  Environment:      ${ENVIRONMENT}"
log "  Domain:           ${DOMAIN}"
log "  Central account:  ${CENTRAL_ACCOUNT}"
log "  RC account:       ${RC_ACCOUNT}"
log "  MC account:       ${MC_ACCOUNT}"
log "  Customer account: ${CUSTOMER_ACCOUNT}"
log ""

# =============================================================================
# IAM Roles — Cross-account role structure
# =============================================================================

log "--- IAM Roles ---"

wait_for_service "iam" "${AWSLOCAL}" iam list-roles

# LocalStack's managed AdministratorAccess policy does not reliably cover all
# actions under ENFORCE_IAM (e.g. eks:CreateCluster, iam:PassRole are denied).
# Work around this by attaching an explicit wildcard inline policy to the root
# user so the init script can bootstrap all resources without restrictions.
log "  Granting full access to root user (for init bootstrap)"
run_aws "iam put-root-bootstrap-policy" \
    "${AWSLOCAL}" iam put-user-policy \
    --user-name root \
    --policy-name LocalStackBootstrapFullAccess \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}' || true

# Create OrganizationAccountAccessRole for each account, matching the real
# cross-account assume-role pattern used by ephemeral-env.sh.
for ACCOUNT_ID in "${CENTRAL_ACCOUNT}" "${RC_ACCOUNT}" "${MC_ACCOUNT}" "${CUSTOMER_ACCOUNT}"; do
    ROLE_NAME="OrganizationAccountAccessRole"
    log "  Creating IAM role: ${ROLE_NAME} (account ${ACCOUNT_ID})"

    TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::${CENTRAL_ACCOUNT}:root"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)
    run_aws "iam create-role ${ROLE_NAME} (account ${ACCOUNT_ID})" \
        "${AWSLOCAL}" iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" \
        --tags "Key=Account,Value=${ACCOUNT_ID}" \
        || true

    # Attach AdministratorAccess — with ENFORCE_IAM=1 enabled, this policy
    # is actively enforced by LocalStack Pro.
    run_aws "iam attach-role-policy ${ROLE_NAME} (account ${ACCOUNT_ID})" \
        "${AWSLOCAL}" iam attach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" \
        || true
done

# Pipeline execution roles used by CodeBuild/CodePipeline
for ROLE_SUFFIX in "pipeline-provisioner" "pipeline-regional" "pipeline-mc"; do
    log "  Creating IAM role: ${ROLE_SUFFIX}"
    run_aws "iam create-role ${ROLE_SUFFIX}" \
        "${AWSLOCAL}" iam create-role \
        --role-name "${ROLE_SUFFIX}" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["codebuild.amazonaws.com","codepipeline.amazonaws.com"]},"Action":"sts:AssumeRole"}]}' \
        || true
done

log "  ✅ IAM roles created"
log ""

# =============================================================================
# IAM Users — Service accounts for IAM-enforced access
# =============================================================================
# With ENFORCE_IAM=1, LocalStack Pro enforces IAM policies on every API call.
# We create per-account IAM users with access keys and appropriate policies so
# that the pipeline, CLI, and tests can authenticate with scoped permissions.

log "--- IAM Users (for IAM enforcement) ---"

# SSM is needed inside create_iam_user() to store access key credentials,
# so ensure it is ready before creating any IAM users.
wait_for_service "ssm" "${AWSLOCAL}" ssm describe-parameters

# Helper: create an IAM user, generate access keys, and attach a policy.
create_iam_user() {
    local user_name="$1"
    local policy_arn="$2"
    local description="$3"

    log "  Creating IAM user: ${user_name} (${description})"

    run_aws "iam create-user ${user_name}" \
        "${AWSLOCAL}" iam create-user \
        --user-name "${user_name}" \
        --tags "Key=Description,Value=${description}" \
        || true

    # Create access keys (idempotent — if keys exist, skip)
    local key_output=""
    key_output=$(run_aws_capture "iam create-access-key ${user_name}" \
        "${AWSLOCAL}" iam create-access-key \
        --user-name "${user_name}" \
        --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
        --output text) || true

    if [ -n "${key_output}" ]; then
        local access_key secret_key
        access_key=$(echo "${key_output}" | awk '{print $1}')
        secret_key=$(echo "${key_output}" | awk '{print $2}')
        echo "    Access Key: ${access_key}"
        echo "    Secret Key: ${secret_key:0:8}..."

        # Store credentials in SSM so other scripts/tests can retrieve them
        run_aws "ssm put-parameter /localstack/iam/${user_name}/access-key-id" \
            "${AWSLOCAL}" ssm put-parameter \
            --name "/localstack/iam/${user_name}/access-key-id" \
            --value "${access_key}" \
            --type SecureString \
            --overwrite || true
        run_aws "ssm put-parameter /localstack/iam/${user_name}/secret-access-key" \
            "${AWSLOCAL}" ssm put-parameter \
            --name "/localstack/iam/${user_name}/secret-access-key" \
            --value "${secret_key}" \
            --type SecureString \
            --overwrite || true
    fi

    run_aws "iam attach-user-policy ${user_name}" \
        "${AWSLOCAL}" iam attach-user-policy \
        --user-name "${user_name}" \
        --policy-arn "${policy_arn}" \
        || true
    echo "    Policy: ${policy_arn}"
}

# Central account admin — full access for pipeline orchestration
create_iam_user "localstack-central-admin" \
    "arn:aws:iam::aws:policy/AdministratorAccess" \
    "Central account admin"

# RC account operator — manages regional cluster infrastructure
create_iam_user "localstack-rc-operator" \
    "arn:aws:iam::aws:policy/AdministratorAccess" \
    "RC account operator"

# MC account operator — manages management cluster infrastructure
create_iam_user "localstack-mc-operator" \
    "arn:aws:iam::aws:policy/AdministratorAccess" \
    "MC account operator"

# Read-only user — for testing least-privilege access patterns
READONLY_POLICY_ARN="arn:aws:iam::000000000001:policy/localstack-readonly"
run_aws "iam create-policy localstack-readonly" \
    "${AWSLOCAL}" iam create-policy \
    --policy-name "localstack-readonly" \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "s3:GetObject",
                    "s3:ListBucket",
                    "ssm:GetParameter",
                    "ssm:GetParametersByPath",
                    "dynamodb:GetItem",
                    "dynamodb:Query",
                    "dynamodb:Scan",
                    "sts:GetCallerIdentity",
                    "iam:GetUser",
                    "iam:ListRoles"
                ],
                "Resource": "*"
            }
        ]
    }' \
    || true

create_iam_user "localstack-readonly" \
    "${READONLY_POLICY_ARN}" \
    "Read-only test user"

log "  ✅ IAM users created"
log ""

# =============================================================================
# SSM Parameters — Config values expected by render.py
# =============================================================================

log "--- SSM Parameters ---"

wait_for_service "ssm" "${AWSLOCAL}" ssm describe-parameters

# Account IDs for the localstack environment (matches ssm:// references in
# config/defaults.yaml: ssm:///infra/<environment>/<region>/account_id)
log "  Putting SSM param: /infra/${ENVIRONMENT}/${AWS_REGION}/account_id"
retry 3 2 run_aws "ssm put-parameter /infra/${ENVIRONMENT}/${AWS_REGION}/account_id" \
    "${AWSLOCAL}" ssm put-parameter \
    --name "/infra/${ENVIRONMENT}/${AWS_REGION}/account_id" \
    --value "${RC_ACCOUNT}" \
    --type String \
    --overwrite || true
echo "  /infra/${ENVIRONMENT}/${AWS_REGION}/account_id = ${RC_ACCOUNT}"

log "  Putting SSM param: /infra/${ENVIRONMENT}/${AWS_REGION}/mc01/account_id"
retry 3 2 run_aws "ssm put-parameter /infra/${ENVIRONMENT}/${AWS_REGION}/mc01/account_id" \
    "${AWSLOCAL}" ssm put-parameter \
    --name "/infra/${ENVIRONMENT}/${AWS_REGION}/mc01/account_id" \
    --value "${MC_ACCOUNT}" \
    --type String \
    --overwrite || true
echo "  /infra/${ENVIRONMENT}/${AWS_REGION}/mc01/account_id = ${MC_ACCOUNT}"

# GitHub token placeholder (mirrors /ephemeral-provider/github-token)
log "  Putting SSM param: /ephemeral-provider/github-token"
retry 3 2 run_aws "ssm put-parameter /ephemeral-provider/github-token" \
    "${AWSLOCAL}" ssm put-parameter \
    --name "/ephemeral-provider/github-token" \
    --value "localstack-mock-github-token" \
    --type SecureString \
    --overwrite || true
echo "  /ephemeral-provider/github-token = <mock>"

# Region OU path (used by bootstrap-central-account.sh)
log "  Putting SSM param: /infra/region-ou-path"
retry 3 2 run_aws "ssm put-parameter /infra/region-ou-path" \
    "${AWSLOCAL}" ssm put-parameter \
    --name "/infra/region-ou-path" \
    --value "ou-localstack-root/ou-localstack-regions" \
    --type String \
    --overwrite || true
echo "  /infra/region-ou-path = ou-localstack-root/ou-localstack-regions"

# SRE UI allowed CIDRs
log "  Putting SSM param: /infra/sre-ui-alb/allowed-source-cidrs"
retry 3 2 run_aws "ssm put-parameter /infra/sre-ui-alb/allowed-source-cidrs" \
    "${AWSLOCAL}" ssm put-parameter \
    --name "/infra/sre-ui-alb/allowed-source-cidrs" \
    --value "0.0.0.0/0" \
    --type String \
    --overwrite || true
echo "  /infra/sre-ui-alb/allowed-source-cidrs = 0.0.0.0/0"

# SNS alerting topic ARN placeholder
log "  Putting SSM param: /infra/${ENVIRONMENT}/${AWS_REGION}/sns-alerting-topic-arn"
retry 3 2 run_aws "ssm put-parameter /infra/${ENVIRONMENT}/${AWS_REGION}/sns-alerting-topic-arn" \
    "${AWSLOCAL}" ssm put-parameter \
    --name "/infra/${ENVIRONMENT}/${AWS_REGION}/sns-alerting-topic-arn" \
    --value "arn:aws:sns:${AWS_REGION}:${RC_ACCOUNT}:localstack-alerting" \
    --type String \
    --overwrite || true
echo "  /infra/${ENVIRONMENT}/${AWS_REGION}/sns-alerting-topic-arn"

log "  ✅ SSM parameters created"
log ""

# =============================================================================
# Route53 — DNS hosted zones
# =============================================================================

log "--- Route53 Hosted Zones ---"

wait_for_service "route53" "${AWSLOCAL}" route53 list-hosted-zones

# Environment zone (matches dns.domain in config)
ENV_ZONE_ID=$(run_aws_capture "route53 create-hosted-zone ${DOMAIN}" \
    "${AWSLOCAL}" route53 create-hosted-zone \
    --name "${DOMAIN}" \
    --caller-reference "localstack-env-$(date +%s)" \
    --query 'HostedZone.Id' --output text) || true
log "  Created zone: ${DOMAIN} (${ENV_ZONE_ID:-<failed>})"

# Regional zone (deployment_name.domain)
REGIONAL_ZONE_ID=$(run_aws_capture "route53 create-hosted-zone ${AWS_REGION}.${DOMAIN}" \
    "${AWSLOCAL}" route53 create-hosted-zone \
    --name "${AWS_REGION}.${DOMAIN}" \
    --caller-reference "localstack-regional-$(date +%s)" \
    --query 'HostedZone.Id' --output text) || true
log "  Created zone: ${AWS_REGION}.${DOMAIN} (${REGIONAL_ZONE_ID:-<failed>})"

log "  ✅ Route53 zones created"
log ""

# =============================================================================
# S3 Buckets — Terraform state and OIDC
# =============================================================================

log "--- S3 Buckets ---"

wait_for_service "s3" "${AWSLOCAL}" s3 ls

# Terraform state buckets (match bootstrap-state.sh naming)
for BUCKET in \
    "terraform-state-${CENTRAL_ACCOUNT}" \
    "terraform-state-${RC_ACCOUNT}-${AWS_REGION}" \
    "terraform-state-${MC_ACCOUNT}-${AWS_REGION}" \
    "hypershift-mc-${AWS_REGION}"; do
    run_aws "s3 mb ${BUCKET}" \
        "${AWSLOCAL}" s3 mb "s3://${BUCKET}" || true
    log "  Created bucket: ${BUCKET}"
done

# Enable versioning on state buckets
for BUCKET in \
    "terraform-state-${CENTRAL_ACCOUNT}" \
    "terraform-state-${RC_ACCOUNT}-${AWS_REGION}" \
    "terraform-state-${MC_ACCOUNT}-${AWS_REGION}"; do
    run_aws "s3api put-bucket-versioning ${BUCKET}" \
        "${AWSLOCAL}" s3api put-bucket-versioning \
        --bucket "${BUCKET}" \
        --versioning-configuration Status=Enabled \
        || true
done

log "  ✅ S3 buckets created"
log ""

# =============================================================================
# VPC — Basic networking infrastructure
# =============================================================================

log "--- VPC Infrastructure ---"

wait_for_service "ec2" "${AWSLOCAL}" ec2 describe-vpcs

# Regional cluster VPC
RC_VPC_ID=$(run_aws_capture "ec2 create-vpc (regional)" \
    "${AWSLOCAL}" ec2 create-vpc \
    --cidr-block "10.0.0.0/16" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=localstack-regional-vpc}]" \
    --query 'Vpc.VpcId' --output text) || true
log "  Created VPC: ${RC_VPC_ID:-<failed>} (regional)"

# Private subnets (3 AZs)
for i in 1 2 3; do
    SUBNET_ID=$(run_aws_capture "ec2 create-subnet (private-${i})" \
        "${AWSLOCAL}" ec2 create-subnet \
        --vpc-id "${RC_VPC_ID}" \
        --cidr-block "10.0.${i}.0/24" \
        --availability-zone "${AWS_REGION}$(echo "$i" | tr '123' 'abc')" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=localstack-regional-private-${i}}]" \
        --query 'Subnet.SubnetId' --output text) || true
    log "  Created subnet: ${SUBNET_ID:-<failed>} (private-${i})"

    # Save the first private subnet for EKS cluster creation
    if [[ "${i}" == "1" ]]; then
        RC_SUBNET_ID="${SUBNET_ID:-}"
    fi
done

# Public subnets (3 AZs)
for i in 1 2 3; do
    SUBNET_ID=$(run_aws_capture "ec2 create-subnet (public-${i})" \
        "${AWSLOCAL}" ec2 create-subnet \
        --vpc-id "${RC_VPC_ID}" \
        --cidr-block "10.0.1${i}.0/24" \
        --availability-zone "${AWS_REGION}$(echo "$i" | tr '123' 'abc')" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=localstack-regional-public-${i}}]" \
        --query 'Subnet.SubnetId' --output text) || true
    log "  Created subnet: ${SUBNET_ID:-<failed>} (public-${i})"
done

# Security groups
RC_SG_ID=$(run_aws_capture "ec2 create-security-group (regional-cluster)" \
    "${AWSLOCAL}" ec2 create-security-group \
    --group-name "localstack-regional-cluster" \
    --description "Regional cluster security group" \
    --vpc-id "${RC_VPC_ID}" \
    --query 'GroupId' --output text) || true
log "  Created security group: ${RC_SG_ID:-<failed>} (regional-cluster)"

BASTION_SG_ID=$(run_aws_capture "ec2 create-security-group (bastion)" \
    "${AWSLOCAL}" ec2 create-security-group \
    --group-name "localstack-regional-bastion" \
    --description "Regional bastion security group" \
    --vpc-id "${RC_VPC_ID}" \
    --query 'GroupId' --output text) || true
log "  Created security group: ${BASTION_SG_ID:-<failed>} (bastion)"

# Management cluster VPC
MC_VPC_ID=$(run_aws_capture "ec2 create-vpc (management)" \
    "${AWSLOCAL}" ec2 create-vpc \
    --cidr-block "10.1.0.0/16" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=localstack-mc01-vpc}]" \
    --query 'Vpc.VpcId' --output text) || true
log "  Created VPC: ${MC_VPC_ID:-<failed>} (management)"

# MC subnet (needed for EKS cluster creation)
MC_SUBNET_ID=$(run_aws_capture "ec2 create-subnet (mc-private-1)" \
    "${AWSLOCAL}" ec2 create-subnet \
    --vpc-id "${MC_VPC_ID}" \
    --cidr-block "10.1.1.0/24" \
    --availability-zone "${AWS_REGION}a" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=localstack-mc01-private-1}]" \
    --query 'Subnet.SubnetId' --output text) || true
log "  Created subnet: ${MC_SUBNET_ID:-<failed>} (mc-private-1)"

log "  ✅ VPC infrastructure created"
log ""

# =============================================================================
# EKS Clusters — k3s-based emulation (LocalStack Pro)
# =============================================================================
# LocalStack Pro emulates EKS using k3s containers. These clusters can be
# used for testing kubectl/helm workflows and kubeconfig generation.

log "--- EKS Clusters ---"

wait_for_service "eks" "${AWSLOCAL}" eks list-clusters

# RC cluster
if [[ -n "${RC_SUBNET_ID:-}" ]]; then
    run_aws "eks create-cluster rc-cluster" \
        "${AWSLOCAL}" eks create-cluster \
        --name "rc-cluster" \
        --role-arn "arn:aws:iam::${RC_ACCOUNT}:role/OrganizationAccountAccessRole" \
        --resources-vpc-config "subnetIds=${RC_SUBNET_ID}" \
        || true
    log "  Created EKS cluster: rc-cluster (regional)"
else
    log "  WARNING: RC_SUBNET_ID not available, skipping rc-cluster creation"
fi

# MC cluster
if [[ -n "${MC_SUBNET_ID:-}" ]]; then
    run_aws "eks create-cluster mc-cluster" \
        "${AWSLOCAL}" eks create-cluster \
        --name "mc-cluster" \
        --role-arn "arn:aws:iam::${MC_ACCOUNT}:role/OrganizationAccountAccessRole" \
        --resources-vpc-config "subnetIds=${MC_SUBNET_ID}" \
        || true
    log "  Created EKS cluster: mc-cluster (management)"
else
    log "  WARNING: MC_SUBNET_ID not available, skipping mc-cluster creation"
fi

# Wait for clusters to become ACTIVE (k3s containers need time to start)
for CLUSTER_NAME in "rc-cluster" "mc-cluster"; do
    log "  Waiting for ${CLUSTER_NAME} to become ACTIVE..."
    EKS_TIMEOUT=120
    EKS_ELAPSED=0
    while true; do
        CLUSTER_STATUS=$(run_aws_capture "eks describe-cluster ${CLUSTER_NAME}" \
            "${AWSLOCAL}" eks describe-cluster \
            --name "${CLUSTER_NAME}" \
            --query 'cluster.status' --output text) || true
        if [[ "${CLUSTER_STATUS}" == "ACTIVE" ]]; then
            log "  ✅ ${CLUSTER_NAME} is ACTIVE"
            break
        fi
        if (( EKS_ELAPSED >= EKS_TIMEOUT )); then
            log "  WARNING: ${CLUSTER_NAME} not ACTIVE after ${EKS_TIMEOUT}s (status: ${CLUSTER_STATUS:-unknown}), proceeding"
            break
        fi
        sleep 5
        (( EKS_ELAPSED += 5 )) || true
    done
done

log "  ✅ EKS clusters created"
log ""

# =============================================================================
# DynamoDB — kube-applier tables
# =============================================================================

log "--- DynamoDB Tables ---"

wait_for_service "dynamodb" "${AWSLOCAL}" dynamodb list-tables

run_aws "dynamodb create-table localstack-kube-applier" \
    "${AWSLOCAL}" dynamodb create-table \
    --table-name "localstack-kube-applier" \
    --attribute-definitions \
        AttributeName=pk,AttributeType=S \
        AttributeName=sk,AttributeType=S \
    --key-schema \
        AttributeName=pk,KeyType=HASH \
        AttributeName=sk,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    || true
log "  Created table: localstack-kube-applier"

log "  ✅ DynamoDB tables created"
log ""

# =============================================================================
# KMS — Encryption keys
# =============================================================================

log "--- KMS Keys ---"

wait_for_service "kms" "${AWSLOCAL}" kms list-keys

KMS_KEY_ID=$(run_aws_capture "kms create-key (EKS secrets)" \
    "${AWSLOCAL}" kms create-key \
    --description "LocalStack EKS secrets encryption key" \
    --query 'KeyMetadata.KeyId' --output text) || true
if [ -n "${KMS_KEY_ID}" ]; then
    run_aws "kms create-alias alias/localstack-eks-secrets" \
        "${AWSLOCAL}" kms create-alias \
        --alias-name "alias/localstack-eks-secrets" \
        --target-key-id "${KMS_KEY_ID}" \
        || true
    log "  Created key: ${KMS_KEY_ID} (alias/localstack-eks-secrets)"
fi

log "  ✅ KMS keys created"
log ""

# =============================================================================
# Secrets Manager — Application secrets
# =============================================================================

log "--- Secrets Manager ---"

wait_for_service "secretsmanager" "${AWSLOCAL}" secretsmanager list-secrets

run_aws "secretsmanager create-secret localstack/argocd-admin" \
    "${AWSLOCAL}" secretsmanager create-secret \
    --name "localstack/argocd-admin" \
    --secret-string '{"username":"admin","password":"localstack-admin"}' \
    || true
log "  Created secret: localstack/argocd-admin"

run_aws "secretsmanager create-secret localstack/hyperfleet-db" \
    "${AWSLOCAL}" secretsmanager create-secret \
    --name "localstack/hyperfleet-db" \
    --secret-string '{"username":"hyperfleet","password":"localstack-db-password","host":"localhost","port":"5432","dbname":"hyperfleet"}' \
    || true
log "  Created secret: localstack/hyperfleet-db"

log "  ✅ Secrets created"
log ""

# =============================================================================
# SNS — Alerting topics
# =============================================================================

log "--- SNS Topics ---"

wait_for_service "sns" "${AWSLOCAL}" sns list-topics

run_aws "sns create-topic localstack-alerting" \
    "${AWSLOCAL}" sns create-topic \
    --name "localstack-alerting" \
    || true
log "  Created topic: localstack-alerting"

log "  ✅ SNS topics created"
log ""

# =============================================================================
# CloudWatch — Log groups
# =============================================================================

log "--- CloudWatch Log Groups ---"

wait_for_service "logs" "${AWSLOCAL}" logs describe-log-groups

for LOG_GROUP in \
    "/aws/eks/localstack-regional/cluster" \
    "/aws/eks/localstack-mc01/cluster" \
    "/aws/codebuild/localstack-pipeline-provisioner" \
    "/aws/codebuild/localstack-pipeline-regional" \
    "/aws/codebuild/localstack-pipeline-mc01"; do
    run_aws "logs create-log-group ${LOG_GROUP}" \
        "${AWSLOCAL}" logs create-log-group \
        --log-group-name "${LOG_GROUP}" \
        || true
    log "  Created log group: ${LOG_GROUP}"
done

log "  ✅ CloudWatch log groups created"
log ""

# =============================================================================
# CodeBuild / CodePipeline — Mock CI/CD pipelines
# =============================================================================

log "--- CodeBuild Projects ---"

wait_for_service "codebuild" "${AWSLOCAL}" codebuild list-projects

for PROJECT in \
    "localstack-pipeline-provisioner" \
    "localstack-pipeline-regional" \
    "localstack-pipeline-mc01"; do
    run_aws "codebuild create-project ${PROJECT}" \
        "${AWSLOCAL}" codebuild create-project \
        --name "${PROJECT}" \
        --source '{"type":"NO_SOURCE","buildspec":"version: 0.2\nphases:\n  build:\n    commands:\n      - echo LocalStack mock build"}' \
        --artifacts '{"type":"NO_ARTIFACTS"}' \
        --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL"}' \
        --service-role "arn:aws:iam::${CENTRAL_ACCOUNT}:role/pipeline-provisioner" \
        || true
    log "  Created project: ${PROJECT}"
done

log "  ✅ CodeBuild projects created"
log ""

log "--- CodePipeline Pipelines ---"

wait_for_service "codepipeline" "${AWSLOCAL}" codepipeline list-pipelines

for PIPELINE in "localstack-pipeline-provisioner" "localstack-pipeline-regional"; do
    run_aws "codepipeline create-pipeline ${PIPELINE}" \
        "${AWSLOCAL}" codepipeline create-pipeline \
        --pipeline "{
            \"name\": \"${PIPELINE}\",
            \"roleArn\": \"arn:aws:iam::${CENTRAL_ACCOUNT}:role/pipeline-provisioner\",
            \"stages\": [
                {
                    \"name\": \"Source\",
                    \"actions\": [{
                        \"name\": \"Source\",
                        \"actionTypeId\": {\"category\": \"Source\", \"owner\": \"AWS\", \"provider\": \"S3\", \"version\": \"1\"},
                        \"configuration\": {\"S3Bucket\": \"terraform-state-${CENTRAL_ACCOUNT}\", \"S3ObjectKey\": \"source.zip\"},
                        \"outputArtifacts\": [{\"name\": \"SourceOutput\"}]
                    }]
                },
                {
                    \"name\": \"Build\",
                    \"actions\": [{
                        \"name\": \"Build\",
                        \"actionTypeId\": {\"category\": \"Build\", \"owner\": \"AWS\", \"provider\": \"CodeBuild\", \"version\": \"1\"},
                        \"configuration\": {\"ProjectName\": \"${PIPELINE}\"},
                        \"inputArtifacts\": [{\"name\": \"SourceOutput\"}]
                    }]
                }
            ],
            \"artifactStore\": {\"type\": \"S3\", \"location\": \"terraform-state-${CENTRAL_ACCOUNT}\"}
        }" \
        || true
    log "  Created pipeline: ${PIPELINE}"
done

log "  ✅ CodePipeline pipelines created"
log ""

# =============================================================================
# Summary
# =============================================================================

echo "============================================================"
echo "  ✅ LocalStack bootstrap complete!"
echo "============================================================"
echo ""
echo "  Endpoint:  http://localhost:4566"
echo "  Region:    ${AWS_REGION}"
echo "  Domain:    ${DOMAIN}"
echo ""
echo "  Accounts:"
echo "    Central:   ${CENTRAL_ACCOUNT}"
echo "    RC:        ${RC_ACCOUNT}"
echo "    MC:        ${MC_ACCOUNT}"
echo "    Customer:  ${CUSTOMER_ACCOUNT}"
echo ""
echo "  IAM enforcement: ENABLED (ENFORCE_IAM=1)"
echo "  IAM policies are actively checked on every API call."
echo ""
echo "  IAM Users (credentials stored in SSM /localstack/iam/<user>/):"
echo "    localstack-central-admin  — Full admin (pipeline orchestration)"
echo "    localstack-rc-operator    — Full admin (regional cluster ops)"
echo "    localstack-mc-operator    — Full admin (management cluster ops)"
echo "    localstack-readonly       — Read-only (least-privilege testing)"
echo ""
echo "  Use 'awslocal' or set AWS_ENDPOINT_URL=http://localhost:4566"
echo "  to interact with LocalStack services."
echo ""
