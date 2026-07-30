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

set -euo pipefail

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

echo "============================================================"
echo "  ROSA HyperFleet — LocalStack Bootstrap"
echo "============================================================"
echo ""
echo "  Region:           ${AWS_REGION}"
echo "  Environment:      ${ENVIRONMENT}"
echo "  Domain:           ${DOMAIN}"
echo "  Central account:  ${CENTRAL_ACCOUNT}"
echo "  RC account:       ${RC_ACCOUNT}"
echo "  MC account:       ${MC_ACCOUNT}"
echo "  Customer account: ${CUSTOMER_ACCOUNT}"
echo ""

# =============================================================================
# IAM Roles — Cross-account role structure
# =============================================================================

echo "--- IAM Roles ---"

# Create OrganizationAccountAccessRole for each account, matching the real
# cross-account assume-role pattern used by ephemeral-env.sh.
for ACCOUNT_ID in "${CENTRAL_ACCOUNT}" "${RC_ACCOUNT}" "${MC_ACCOUNT}" "${CUSTOMER_ACCOUNT}"; do
    ROLE_NAME="OrganizationAccountAccessRole"
    echo "  Creating IAM role: ${ROLE_NAME} (account ${ACCOUNT_ID})"

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
    $AWSLOCAL iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" \
        --tags "Key=Account,Value=${ACCOUNT_ID}" \
        --no-cli-pager 2>/dev/null || true

    # Attach AdministratorAccess — with ENFORCE_IAM=1 enabled, this policy
    # is actively enforced by LocalStack Pro.
    $AWSLOCAL iam attach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" \
        --no-cli-pager 2>/dev/null || true
done

# Pipeline execution roles used by CodeBuild/CodePipeline
for ROLE_SUFFIX in "pipeline-provisioner" "pipeline-regional" "pipeline-mc"; do
    echo "  Creating IAM role: ${ROLE_SUFFIX}"
    $AWSLOCAL iam create-role \
        --role-name "${ROLE_SUFFIX}" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["codebuild.amazonaws.com","codepipeline.amazonaws.com"]},"Action":"sts:AssumeRole"}]}' \
        --no-cli-pager 2>/dev/null || true
done

echo "  ✅ IAM roles created"
echo ""

# =============================================================================
# IAM Users — Service accounts for IAM-enforced access
# =============================================================================
# With ENFORCE_IAM=1, LocalStack Pro enforces IAM policies on every API call.
# We create per-account IAM users with access keys and appropriate policies so
# that the pipeline, CLI, and tests can authenticate with scoped permissions.

echo "--- IAM Users (for IAM enforcement) ---"

# Helper: create an IAM user, generate access keys, and attach a policy.
create_iam_user() {
    local user_name="$1"
    local policy_arn="$2"
    local description="$3"

    echo "  Creating IAM user: ${user_name} (${description})"

    $AWSLOCAL iam create-user \
        --user-name "${user_name}" \
        --tags "Key=Description,Value=${description}" \
        --no-cli-pager 2>/dev/null || true

    # Create access keys (idempotent — if keys exist, skip)
    local key_output
    key_output=$($AWSLOCAL iam create-access-key \
        --user-name "${user_name}" \
        --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
        --output text --no-cli-pager 2>/dev/null) || true

    if [ -n "${key_output}" ]; then
        local access_key secret_key
        access_key=$(echo "${key_output}" | awk '{print $1}')
        secret_key=$(echo "${key_output}" | awk '{print $2}')
        echo "    Access Key: ${access_key}"
        echo "    Secret Key: ${secret_key:0:8}..."

        # Store credentials in SSM so other scripts/tests can retrieve them
        $AWSLOCAL ssm put-parameter \
            --name "/localstack/iam/${user_name}/access-key-id" \
            --value "${access_key}" \
            --type SecureString \
            --overwrite --no-cli-pager 2>/dev/null || true
        $AWSLOCAL ssm put-parameter \
            --name "/localstack/iam/${user_name}/secret-access-key" \
            --value "${secret_key}" \
            --type SecureString \
            --overwrite --no-cli-pager 2>/dev/null || true
    fi

    $AWSLOCAL iam attach-user-policy \
        --user-name "${user_name}" \
        --policy-arn "${policy_arn}" \
        --no-cli-pager 2>/dev/null || true
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
$AWSLOCAL iam create-policy \
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
    --no-cli-pager 2>/dev/null || true

create_iam_user "localstack-readonly" \
    "${READONLY_POLICY_ARN}" \
    "Read-only test user"

echo "  ✅ IAM users created"
echo ""

# =============================================================================
# SSM Parameters — Config values expected by render.py
# =============================================================================

echo "--- SSM Parameters ---"

# Account IDs for the localstack environment (matches ssm:// references in
# config/defaults.yaml: ssm:///infra/<environment>/<region>/account_id)
$AWSLOCAL ssm put-parameter \
    --name "/infra/${ENVIRONMENT}/${AWS_REGION}/account_id" \
    --value "${RC_ACCOUNT}" \
    --type String \
    --overwrite --no-cli-pager 2>/dev/null
echo "  /infra/${ENVIRONMENT}/${AWS_REGION}/account_id = ${RC_ACCOUNT}"

$AWSLOCAL ssm put-parameter \
    --name "/infra/${ENVIRONMENT}/${AWS_REGION}/mc01/account_id" \
    --value "${MC_ACCOUNT}" \
    --type String \
    --overwrite --no-cli-pager 2>/dev/null
echo "  /infra/${ENVIRONMENT}/${AWS_REGION}/mc01/account_id = ${MC_ACCOUNT}"

# GitHub token placeholder (mirrors /ephemeral-provider/github-token)
$AWSLOCAL ssm put-parameter \
    --name "/ephemeral-provider/github-token" \
    --value "localstack-mock-github-token" \
    --type SecureString \
    --overwrite --no-cli-pager 2>/dev/null
echo "  /ephemeral-provider/github-token = <mock>"

# Region OU path (used by bootstrap-central-account.sh)
$AWSLOCAL ssm put-parameter \
    --name "/infra/region-ou-path" \
    --value "ou-localstack-root/ou-localstack-regions" \
    --type String \
    --overwrite --no-cli-pager 2>/dev/null
echo "  /infra/region-ou-path = ou-localstack-root/ou-localstack-regions"

# SRE UI allowed CIDRs
$AWSLOCAL ssm put-parameter \
    --name "/infra/sre-ui-alb/allowed-source-cidrs" \
    --value "0.0.0.0/0" \
    --type String \
    --overwrite --no-cli-pager 2>/dev/null
echo "  /infra/sre-ui-alb/allowed-source-cidrs = 0.0.0.0/0"

# SNS alerting topic ARN placeholder
$AWSLOCAL ssm put-parameter \
    --name "/infra/${ENVIRONMENT}/${AWS_REGION}/sns-alerting-topic-arn" \
    --value "arn:aws:sns:${AWS_REGION}:${RC_ACCOUNT}:localstack-alerting" \
    --type String \
    --overwrite --no-cli-pager 2>/dev/null
echo "  /infra/${ENVIRONMENT}/${AWS_REGION}/sns-alerting-topic-arn"

echo "  ✅ SSM parameters created"
echo ""

# =============================================================================
# Route53 — DNS hosted zones
# =============================================================================

echo "--- Route53 Hosted Zones ---"

# Environment zone (matches dns.domain in config)
ENV_ZONE_ID=$($AWSLOCAL route53 create-hosted-zone \
    --name "${DOMAIN}" \
    --caller-reference "localstack-env-$(date +%s)" \
    --query 'HostedZone.Id' --output text --no-cli-pager 2>/dev/null || echo "")
echo "  Created zone: ${DOMAIN} (${ENV_ZONE_ID})"

# Regional zone (deployment_name.domain)
REGIONAL_ZONE_ID=$($AWSLOCAL route53 create-hosted-zone \
    --name "${AWS_REGION}.${DOMAIN}" \
    --caller-reference "localstack-regional-$(date +%s)" \
    --query 'HostedZone.Id' --output text --no-cli-pager 2>/dev/null || echo "")
echo "  Created zone: ${AWS_REGION}.${DOMAIN} (${REGIONAL_ZONE_ID})"

echo "  ✅ Route53 zones created"
echo ""

# =============================================================================
# S3 Buckets — Terraform state and OIDC
# =============================================================================

echo "--- S3 Buckets ---"

# Terraform state buckets (match bootstrap-state.sh naming)
for BUCKET in \
    "terraform-state-${CENTRAL_ACCOUNT}" \
    "terraform-state-${RC_ACCOUNT}-${AWS_REGION}" \
    "terraform-state-${MC_ACCOUNT}-${AWS_REGION}" \
    "hypershift-mc-${AWS_REGION}"; do
    $AWSLOCAL s3 mb "s3://${BUCKET}" --no-cli-pager 2>/dev/null || true
    echo "  Created bucket: ${BUCKET}"
done

# Enable versioning on state buckets
for BUCKET in \
    "terraform-state-${CENTRAL_ACCOUNT}" \
    "terraform-state-${RC_ACCOUNT}-${AWS_REGION}" \
    "terraform-state-${MC_ACCOUNT}-${AWS_REGION}"; do
    $AWSLOCAL s3api put-bucket-versioning \
        --bucket "${BUCKET}" \
        --versioning-configuration Status=Enabled \
        --no-cli-pager 2>/dev/null || true
done

echo "  ✅ S3 buckets created"
echo ""

# =============================================================================
# VPC — Basic networking infrastructure
# =============================================================================

echo "--- VPC Infrastructure ---"

# Regional cluster VPC
RC_VPC_ID=$($AWSLOCAL ec2 create-vpc \
    --cidr-block "10.0.0.0/16" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=localstack-regional-vpc}]" \
    --query 'Vpc.VpcId' --output text --no-cli-pager 2>/dev/null)
echo "  Created VPC: ${RC_VPC_ID} (regional)"

# Private subnets (3 AZs)
for i in 1 2 3; do
    SUBNET_ID=$($AWSLOCAL ec2 create-subnet \
        --vpc-id "${RC_VPC_ID}" \
        --cidr-block "10.0.${i}.0/24" \
        --availability-zone "${AWS_REGION}$(echo $i | tr '123' 'abc')" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=localstack-regional-private-${i}}]" \
        --query 'Subnet.SubnetId' --output text --no-cli-pager 2>/dev/null)
    echo "  Created subnet: ${SUBNET_ID} (private-${i})"
done

# Public subnets (3 AZs)
for i in 1 2 3; do
    SUBNET_ID=$($AWSLOCAL ec2 create-subnet \
        --vpc-id "${RC_VPC_ID}" \
        --cidr-block "10.0.1${i}.0/24" \
        --availability-zone "${AWS_REGION}$(echo $i | tr '123' 'abc')" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=localstack-regional-public-${i}}]" \
        --query 'Subnet.SubnetId' --output text --no-cli-pager 2>/dev/null)
    echo "  Created subnet: ${SUBNET_ID} (public-${i})"
done

# Security groups
RC_SG_ID=$($AWSLOCAL ec2 create-security-group \
    --group-name "localstack-regional-cluster" \
    --description "Regional cluster security group" \
    --vpc-id "${RC_VPC_ID}" \
    --query 'GroupId' --output text --no-cli-pager 2>/dev/null)
echo "  Created security group: ${RC_SG_ID} (regional-cluster)"

BASTION_SG_ID=$($AWSLOCAL ec2 create-security-group \
    --group-name "localstack-regional-bastion" \
    --description "Regional bastion security group" \
    --vpc-id "${RC_VPC_ID}" \
    --query 'GroupId' --output text --no-cli-pager 2>/dev/null)
echo "  Created security group: ${BASTION_SG_ID} (bastion)"

# Management cluster VPC
MC_VPC_ID=$($AWSLOCAL ec2 create-vpc \
    --cidr-block "10.1.0.0/16" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=localstack-mc01-vpc}]" \
    --query 'Vpc.VpcId' --output text --no-cli-pager 2>/dev/null)
echo "  Created VPC: ${MC_VPC_ID} (management)"

echo "  ✅ VPC infrastructure created"
echo ""

# =============================================================================
# DynamoDB — kube-applier tables
# =============================================================================

echo "--- DynamoDB Tables ---"

$AWSLOCAL dynamodb create-table \
    --table-name "localstack-kube-applier" \
    --attribute-definitions \
        AttributeName=pk,AttributeType=S \
        AttributeName=sk,AttributeType=S \
    --key-schema \
        AttributeName=pk,KeyType=HASH \
        AttributeName=sk,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --no-cli-pager 2>/dev/null || true
echo "  Created table: localstack-kube-applier"

echo "  ✅ DynamoDB tables created"
echo ""

# =============================================================================
# KMS — Encryption keys
# =============================================================================

echo "--- KMS Keys ---"

KMS_KEY_ID=$($AWSLOCAL kms create-key \
    --description "LocalStack EKS secrets encryption key" \
    --query 'KeyMetadata.KeyId' --output text --no-cli-pager 2>/dev/null || echo "")
if [ -n "${KMS_KEY_ID}" ]; then
    $AWSLOCAL kms create-alias \
        --alias-name "alias/localstack-eks-secrets" \
        --target-key-id "${KMS_KEY_ID}" \
        --no-cli-pager 2>/dev/null || true
    echo "  Created key: ${KMS_KEY_ID} (alias/localstack-eks-secrets)"
fi

echo "  ✅ KMS keys created"
echo ""

# =============================================================================
# Secrets Manager — Application secrets
# =============================================================================

echo "--- Secrets Manager ---"

$AWSLOCAL secretsmanager create-secret \
    --name "localstack/argocd-admin" \
    --secret-string '{"username":"admin","password":"localstack-admin"}' \
    --no-cli-pager 2>/dev/null || true
echo "  Created secret: localstack/argocd-admin"

$AWSLOCAL secretsmanager create-secret \
    --name "localstack/hyperfleet-db" \
    --secret-string '{"username":"hyperfleet","password":"localstack-db-password","host":"localhost","port":"5432","dbname":"hyperfleet"}' \
    --no-cli-pager 2>/dev/null || true
echo "  Created secret: localstack/hyperfleet-db"

echo "  ✅ Secrets created"
echo ""

# =============================================================================
# SNS — Alerting topics
# =============================================================================

echo "--- SNS Topics ---"

$AWSLOCAL sns create-topic \
    --name "localstack-alerting" \
    --no-cli-pager 2>/dev/null || true
echo "  Created topic: localstack-alerting"

echo "  ✅ SNS topics created"
echo ""

# =============================================================================
# CloudWatch — Log groups
# =============================================================================

echo "--- CloudWatch Log Groups ---"

for LOG_GROUP in \
    "/aws/eks/localstack-regional/cluster" \
    "/aws/eks/localstack-mc01/cluster" \
    "/aws/codebuild/localstack-pipeline-provisioner" \
    "/aws/codebuild/localstack-pipeline-regional" \
    "/aws/codebuild/localstack-pipeline-mc01"; do
    $AWSLOCAL logs create-log-group \
        --log-group-name "${LOG_GROUP}" \
        --no-cli-pager 2>/dev/null || true
    echo "  Created log group: ${LOG_GROUP}"
done

echo "  ✅ CloudWatch log groups created"
echo ""

# =============================================================================
# CodeBuild / CodePipeline — Mock CI/CD pipelines
# =============================================================================

echo "--- CodeBuild Projects ---"

for PROJECT in \
    "localstack-pipeline-provisioner" \
    "localstack-pipeline-regional" \
    "localstack-pipeline-mc01"; do
    $AWSLOCAL codebuild create-project \
        --name "${PROJECT}" \
        --source '{"type":"NO_SOURCE","buildspec":"version: 0.2\nphases:\n  build:\n    commands:\n      - echo LocalStack mock build"}' \
        --artifacts '{"type":"NO_ARTIFACTS"}' \
        --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL"}' \
        --service-role "arn:aws:iam::${CENTRAL_ACCOUNT}:role/pipeline-provisioner" \
        --no-cli-pager 2>/dev/null || true
    echo "  Created project: ${PROJECT}"
done

echo "  ✅ CodeBuild projects created"
echo ""

echo "--- CodePipeline Pipelines ---"

for PIPELINE in "localstack-pipeline-provisioner" "localstack-pipeline-regional"; do
    $AWSLOCAL codepipeline create-pipeline \
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
        --no-cli-pager 2>/dev/null || true
    echo "  Created pipeline: ${PIPELINE}"
done

echo "  ✅ CodePipeline pipelines created"
echo ""

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
