# Shared IAM role for ALL Management Cluster CodeBuild projects
#
# This role is shared by all MC projects (mc01, mc02, ..., mcNN) to reduce
# IAM role proliferation as the number of MCs scales. The role uses wildcard
# patterns (mc*) to grant permissions to all numeric MC resources.

data "aws_caller_identity" "mc_shared" {}

resource "aws_iam_role" "mc_codebuild_role" {
  name = "${local.iam_role_prefix}mc-codebuild-role"

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

resource "aws_iam_role_policy" "mc_codebuild_policy" {
  role = aws_iam_role.mc_codebuild_role.name

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
          # Explicit suffixes for the 4 MC CodeBuild project types
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:/aws/codebuild/mc*-apply",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:/aws/codebuild/mc*-apply:*",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:/aws/codebuild/mc*-bootstrap",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:/aws/codebuild/mc*-bootstrap:*",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:/aws/codebuild/mc*-register",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:/aws/codebuild/mc*-register:*",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:/aws/codebuild/mc*-kube-applier-dynamodb",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:/aws/codebuild/mc*-kube-applier-dynamodb:*"
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
          "arn:aws:s3:::mc*-artifacts-*",
          "arn:aws:s3:::mc*-artifacts-*/*",
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
          "arn:aws:ssm:*:${data.aws_caller_identity.mc_shared.account_id}:parameter/infra/*"
        ]
      },
      {
        Sid    = "CheckQueueSelfScope"
        Effect = "Allow"
        Action = [
          "codebuild:ListBuildsForProject",
          "codebuild:BatchGetBuilds",
          "codebuild:StopBuild"
        ]
        Resource = "arn:aws:codebuild:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:project/mc*"
      },
      {
        # Cross-account assume role for child MC accounts. Account IDs are
        # runtime-resolved from SSM parameters and cannot be hardcoded here.
        # This is intentionally scoped to the specific role name only.
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::*:role/rosa-hyperfleet-account-admin"
      },
      # Permissions for same-account operations (when TARGET_ACCOUNT_ID == CENTRAL_ACCOUNT_ID)
      # In production, cross-account deployments should use OrganizationAccountAccessRole
      # These permissions allow Terraform to provision management cluster infrastructure
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
              "ecs-tasks.amazonaws.com"
            ]
          }
        }
      }
    ]
  })
}
