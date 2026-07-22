provider "aws" {
  region = var.region
  # FedRAMP SC-13 / IA-07: Use FIPS 140-2 validated endpoints when available.
  # FIPS endpoints exist only in US and GovCloud regions; non-US regions (EU, AP, SA)
  # do not support FIPS endpoints and will fail if this is set to true.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # management_id is already unique per environment/CI run
  name_prefix    = var.management_id
  account_suffix = substr(data.aws_caller_identity.current.account_id, -8, 8)

  # Resource naming: {name_prefix}-{resource-type}
  artifact_bucket_name               = "${local.name_prefix}-artifacts-${local.account_suffix}"
  codebuild_role_name                = "${local.name_prefix}-codebuild-role"
  codepipeline_role_name             = "${local.name_prefix}-codepipeline-role"
  apply_project_name                 = "${local.name_prefix}-apply"
  kube_applier_dynamodb_project_name = "${local.name_prefix}-kube-applier-dynamodb"
  bootstrap_project_name             = "${local.name_prefix}-bootstrap"
  register_project_name              = "${local.name_prefix}-register"
  pipeline_name                      = "${local.name_prefix}-pipe"

  # Repository URL constructed from github_repository variable
  repository_url = "https://github.com/${var.github_repository}.git"
}

# Use shared GitHub Connection (passed from pipeline-provisioner)
data "aws_codestarconnections_connection" "github" {
  arn = var.github_connection_arn
}

# IAM Role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = local.codebuild_role_name

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

resource "aws_iam_role_policy" "codebuild_policy" {
  role = aws_iam_role.codebuild_role.name

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
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.management_apply.name}",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.management_apply.name}:*",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.management_bootstrap.name}",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.management_bootstrap.name}:*",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.register.name}",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.register.name}:*",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.kube_applier_dynamodb.name}",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.kube_applier_dynamodb.name}:*"
        ]
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
          aws_s3_bucket.pipeline_artifact.arn,
          "${aws_s3_bucket.pipeline_artifact.arn}/*",
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
          "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/infra/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::*:role/OrganizationAccountAccessRole"
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
          "iam:PassRole",
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
      }
    ]
  })
}

# IAM Role for CodePipeline
resource "aws_iam_role" "codepipeline_role" {
  name = local.codepipeline_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  role = aws_iam_role.codepipeline_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:PutObjectAcl",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifact.arn,
          "${aws_s3_bucket.pipeline_artifact.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codestar-connections:UseConnection"
        ]
        Resource = data.aws_codestarconnections_connection.github.arn
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = [
          aws_codebuild_project.management_apply.arn,
          aws_codebuild_project.kube_applier_dynamodb.arn,
          aws_codebuild_project.management_bootstrap.arn,
          aws_codebuild_project.register.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild"
        ]
        Resource = [
          "arn:aws:codebuild:*:*:project/${aws_codebuild_project.management_apply.name}",
          "arn:aws:codebuild:*:*:project/${aws_codebuild_project.kube_applier_dynamodb.name}",
          "arn:aws:codebuild:*:*:project/${aws_codebuild_project.management_bootstrap.name}",
          "arn:aws:codebuild:*:*:project/${aws_codebuild_project.register.name}"
        ]
      }
    ]
  })
}

# S3 Bucket for Artifacts
resource "aws_s3_bucket" "pipeline_artifact" {
  bucket        = local.artifact_bucket_name
  force_destroy = true # Allow deletion even if bucket contains objects

  timeouts {
    create = "30s" # Fail fast if bucket creation hangs (explicit names should be instant)
    delete = "2m"
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_s3_bucket_versioning" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# CodeBuild Project - Apply
resource "aws_codebuild_project" "management_apply" {
  name          = local.apply_project_name
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 60

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    # AWS account where Management Cluster will be deployed
    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    # AWS region for Management Cluster deployment
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    # Unique identifier for deploying multiple clusters per region
    environment_variable {
      name  = "MANAGEMENT_ID"
      value = var.management_id
    }
    # Environment name (staging/production)
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.target_environment
    }
    # Git repository URL for ArgoCD configuration
    environment_variable {
      name  = "REPOSITORY_URL"
      value = var.repository_url
    }
    # Git branch for ArgoCD configuration
    environment_variable {
      name  = "REPOSITORY_BRANCH"
      value = var.repository_branch
    }
    environment_variable {
      name  = "PLATFORM_IMAGE"
      value = var.codebuild_image
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-management-cluster/buildspec-provision-infra.yml"
  }
}

# CodeBuild Project - Bootstrap ArgoCD
resource "aws_codebuild_project" "management_bootstrap" {
  name          = local.bootstrap_project_name
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 75

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Required for Docker builds

    # AWS account where Management Cluster is deployed
    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    # Unique identifier for the cluster
    environment_variable {
      name  = "MANAGEMENT_ID"
      value = var.management_id
    }
    # AWS region for bootstrap operations
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    # Environment name (staging/production)
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.target_environment
    }
    # Git repository URL for ArgoCD bootstrap
    environment_variable {
      name  = "REPOSITORY_URL"
      value = var.repository_url
    }
    # Git branch for ArgoCD bootstrap
    environment_variable {
      name  = "REPOSITORY_BRANCH"
      value = var.repository_branch
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-management-cluster/buildspec-bootstrap-argocd.yml"
  }
}

# CodeBuild Project - Register MC with Regional Cluster API
resource "aws_codebuild_project" "register" {
  name          = local.register_project_name
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 15

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    # AWS account where Management Cluster is deployed
    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    # AWS region for the deployment
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    # Unique identifier for this management cluster pipeline
    environment_variable {
      name  = "MANAGEMENT_ID"
      value = var.management_id
    }
    # Environment name (staging/production)
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.target_environment
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-management-cluster/buildspec-register.yml"
  }
}

# CodeBuild Project - kube-applier DynamoDB provisioning (runs in RC account)
resource "aws_codebuild_project" "kube_applier_dynamodb" {
  name          = local.kube_applier_dynamodb_project_name
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 15

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    environment_variable {
      name  = "MANAGEMENT_ID"
      value = var.management_id
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.target_environment
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-management-cluster/buildspec-provision-kube-applier-dynamodb.yml"
  }
}

# Allow time for IAM policy propagation before creating the pipeline.
# Pipelines auto-trigger on creation; without this delay the Source action
# can fail with "Access Denied" on the CodeStar connection.
resource "time_sleep" "iam_propagation" {
  depends_on = [
    aws_iam_role_policy.codebuild_policy,
    aws_iam_role_policy.codepipeline_policy,
  ]
  create_duration = "15s"
}

# CodePipeline
resource "aws_codepipeline" "regional_pipeline" {
  name          = local.pipeline_name
  role_arn      = aws_iam_role.codepipeline_role.arn
  pipeline_type = "V2"

  depends_on = [time_sleep.iam_propagation]

  variable {
    name          = "IS_DESTROY"
    default_value = "false"
  }

  artifact_store {
    location = aws_s3_bucket.pipeline_artifact.bucket
    type     = "S3"
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.github_branch]
        }
        file_paths {
          includes = ["deploy/${var.target_environment}/${var.target_region}/pipeline-management-cluster-${local.name_prefix}-inputs/terraform.json", "terraform/config/pipeline-management-cluster/**", "terraform/config/kube-applier-dynamodb-provisioning/**"]
        }
      }
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = data.aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repository
        BranchName       = var.github_branch
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name             = "ApplyInfrastructure"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["apply_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.management_apply.name
        EnvironmentVariables = jsonencode([
          {
            name  = "IS_DESTROY"
            value = "#{variables.IS_DESTROY}"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  stage {
    name = "Provision-KubeApplier-DynamoDB"

    action {
      name            = "KubeApplierDynamoDB"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["apply_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.kube_applier_dynamodb.name
        EnvironmentVariables = jsonencode([
          {
            name  = "IS_DESTROY"
            value = "#{variables.IS_DESTROY}"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  stage {
    name = "Bootstrap-ArgoCD"

    action {
      name            = "BootstrapArgoCD"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["apply_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.management_bootstrap.name
        EnvironmentVariables = jsonencode([
          {
            name  = "IS_DESTROY"
            value = "#{variables.IS_DESTROY}"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  stage {
    name = "Register"

    action {
      name            = "RegisterWithRC"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.register.name
        EnvironmentVariables = jsonencode([
          {
            name  = "IS_DESTROY"
            value = "#{variables.IS_DESTROY}"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }
}

# Pipeline Failure Notifications
# Only enable for specific environments (staging, production, integration)
module "pipeline_notifications" {
  source = "../../modules/pipeline-notifications"
  count  = contains(["stage", "staging", "production", "integration"], var.target_environment) ? 1 : 0

  slack_webhook_ssm_param = var.slack_webhook_ssm_param
  name_prefix             = local.name_prefix
  region                  = var.region
  pipeline_names          = [aws_codepipeline.regional_pipeline.name]
}
