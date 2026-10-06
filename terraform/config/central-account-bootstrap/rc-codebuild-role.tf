# Shared IAM role for Regional Cluster CodeBuild projects
#
# This role is used by SDK-created RC CodeBuild projects (one per region).
# The role name is referenced by ARN in the SDK provisioner script.

data "aws_caller_identity" "rc_shared" {}

resource "aws_iam_role" "rc_codebuild_role" {
  name = "${local.iam_role_prefix}rc-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "rc_codebuild_policy" {
  role = aws_iam_role.rc_codebuild_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          # RC CodeBuild project logs (name pattern: {regional_id}, e.g., "regional" or "abc123-regional")
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.rc_shared.account_id}:log-group:/aws/codebuild/*regional*",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.rc_shared.account_id}:log-group:/aws/codebuild/*regional*:*"
        ]
      },
      {
        Sid    = "GitHubConnectionAccess"
        Effect = "Allow"
        Action = [
          "codestar-connections:GetConnection",
          "codestar-connections:GetConnectionToken",
          "codestar-connections:UseConnection"
        ]
        Resource = aws_codestarconnections_connection.github.arn
      },
      {
        Sid    = "CheckQueueSelfScope"
        Effect = "Allow"
        Action = [
          "codebuild:ListBuildsForProject",
          "codebuild:BatchGetBuilds",
          "codebuild:StopBuild"
        ]
        Resource = "arn:aws:codebuild:${var.region}:${data.aws_caller_identity.rc_shared.account_id}:project/*regional*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::terraform-state-*",
          "arn:aws:s3:::terraform-state-*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          "arn:aws:ssm:*:${data.aws_caller_identity.rc_shared.account_id}:parameter/infra/*"
        ]
      },
      {
        # Cross-account assume role for child RC accounts. Account IDs are
        # runtime-resolved from SSM parameters and cannot be hardcoded here.
        # Support the ephemeral OrganizationAccountAccessRole and the scoped
        # production role; both are constrained to exact role names.
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          "arn:aws:iam::*:role/OrganizationAccountAccessRole",
          "arn:aws:iam::*:role/rosa-hyperfleet-account-admin"
        ]
      },
      # Permissions for same-account operations (when TARGET_ACCOUNT_ID == CENTRAL_ACCOUNT_ID)
      # These permissions allow Terraform to provision regional cluster infrastructure
      {
        Effect = "Allow"
        Action = [
          # EC2/VPC - Full permissions for networking infrastructure
          "ec2:*",
          # EKS - Full permissions for cluster management
          "eks:*",
          # ECS - For bootstrap cluster operations
          "ecs:CreateCluster",
          "ecs:DeleteCluster",
          "ecs:DescribeClusters",
          "ecs:ListClusters",
          "ecs:PutClusterCapacityProviders",
          "ecs:TagResource",
          "ecs:UntagResource",
          "ecs:RegisterTaskDefinition",
          "ecs:DeregisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTaskDefinitions",
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          # RDS - For hyperfleet-db
          "rds:*",
          # ElastiCache - For Valkey rate limiting
          "elasticache:*",
          # Secrets Manager - For ECS bootstrap and cluster secrets
          "secretsmanager:*",
          # IAM - For creating cluster roles and policies
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagRole",
          "iam:TagPolicy",
          "iam:UntagRole",
          "iam:UntagPolicy",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UntagOpenIDConnectProvider",
          "iam:CreateServiceLinkedRole",
          "iam:GetServiceLinkedRoleDeletionStatus",
          "iam:DeleteServiceLinkedRole",
          # KMS - For encryption
          "kms:CreateKey",
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:DescribeKey",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:EnableKeyRotation",
          "kms:DisableKeyRotation",
          "kms:ListAliases",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant",
          "kms:RetireGrant",
          # Route53 - For DNS management
          "route53:*",
          # DynamoDB - For kube-applier state (RC provisions MC's DynamoDB)
          "dynamodb:*",
          # Logs - For EKS control plane logs and ECS task logs
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DescribeLogGroups",
          "logs:ListTagsLogGroup",
          "logs:ListTagsForResource",
          "logs:TagResource",
          "logs:UntagResource",
          "logs:PutRetentionPolicy",
          "logs:TagLogGroup",
          "logs:UntagLogGroup"
        ]
        Resource = "*"
      },
      {
        # IAM PassRole restricted to EKS and ECS services only
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "eks.amazonaws.com",
              "ecs-tasks.amazonaws.com",
              "rds.amazonaws.com",
              "elasticache.amazonaws.com"
            ]
          }
        }
      }
    ]
  })
}
