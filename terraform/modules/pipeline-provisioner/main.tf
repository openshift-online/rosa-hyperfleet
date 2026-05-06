provider "aws" {
  region = var.region
  # FedRAMP SC-13 / IA-07: Use FIPS 140-2 validated endpoints when available.
  # FIPS endpoints exist only in US and GovCloud regions; non-US regions (EU, AP, SA)
  # do not support FIPS endpoints and will fail if this is set to true.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  default_tags {
    tags = {
      "app"                    = var.app
      "app-code"               = var.app_code
      "cost-center"            = var.cost_center
      "managed_by_integration" = "https://github.com/openshift-online/rosa-regional-platform/terraform/modules/pipeline-provisioner"
      "organization"           = var.organization
      "owner"                  = var.owner
      "service-phase"          = var.service_phase
      "environment"            = var.environment
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # When name_prefix is set (e.g., "abc123"), names become "abc123-provisioner-artifacts", etc.
  name_prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""
}

# Use shared GitHub Connection (created in central-account-bootstrap)
data "aws_codestarconnections_connection" "github" {
  arn = var.github_connection_arn
}

# S3 Bucket for Artifacts
resource "aws_s3_bucket" "pipeline_artifact" {
  bucket        = "${local.name_prefix}provisioner-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # Allow deletion even if bucket contains objects
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

# KMS key for pipeline artifact bucket (FedRAMP AU-09: protect audit information at rest)
resource "aws_kms_key" "pipeline_artifact" {
  description             = "KMS CMK for pipeline artifact S3 bucket encryption (FedRAMP AU-09/SC-28)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowBuildPlatformImageRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.build_platform_image_role.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowPipelineRoles"
        Effect = "Allow"
        Principal = {
          AWS = [
            aws_iam_role.codepipeline_role.arn,
            aws_iam_role.codebuild_role.arn,
          ]
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}pipeline-artifact"
  }
}

resource "aws_kms_alias" "pipeline_artifact" {
  name          = "alias/${local.name_prefix}pipeline-artifact"
  target_key_id = aws_kms_key.pipeline_artifact.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pipeline_artifact.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# CodeBuild Project - Pipeline Provisioner
resource "aws_codebuild_project" "provisioner" {
  name          = "${local.name_prefix}provisioner-project"
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

    environment_variable {
      name  = "GITHUB_REPOSITORY"
      value = var.github_repository
    }
    environment_variable {
      name  = "GITHUB_BRANCH"
      value = var.github_branch
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
    environment_variable {
      name  = "GITHUB_CONNECTION_ARN"
      value = data.aws_codestarconnections_connection.github.arn
    }
    environment_variable {
      name  = "PLATFORM_IMAGE"
      value = var.codebuild_image
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/modules/pipeline-provisioner/buildspec.yml"
  }
}

# CodeBuild Project - Build Platform Image
resource "aws_codebuild_project" "build_platform_image" {
  name          = "${local.name_prefix}build-platform-image"
  service_role  = aws_iam_role.build_platform_image_role.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "PLATFORM_ECR_REPO"
      value = var.platform_ecr_repo
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/modules/pipeline-provisioner/buildspec-build-image.yml"
  }
}

# Allow time for IAM policy propagation before creating the pipeline.
# Pipelines auto-trigger on creation; without this delay the Source action
# can fail with "Access Denied" on the CodeStar connection.
resource "time_sleep" "iam_propagation" {
  depends_on = [
    aws_iam_role_policy.codepipeline_policy,
    aws_iam_role_policy.codebuild_policy,
    aws_iam_role_policy.codebuild_state_bootstrap,
    aws_iam_role_policy.build_platform_image_policy,
  ]
  create_duration = "15s"
}

# CodePipeline - Pipeline Provisioner
resource "aws_codepipeline" "provisioner" {
  name           = "${local.name_prefix}pipeline-provisioner"
  role_arn       = aws_iam_role.codepipeline_role.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED" # Prevent parallel executions that could cause lock conflicts

  depends_on = [time_sleep.iam_propagation]

  variable {
    name          = "FORCE_DELETE_ALL_PIPELINES"
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
          includes = [
            "deploy/${var.environment}/*/pipeline-provisioner-inputs/**",
            "terraform/config/pipeline-regional-cluster/**",
            "terraform/config/pipeline-management-cluster/**",
            "terraform/modules/platform-image/**",
            "scripts/build-platform-image.sh"
          ]
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
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Build-Platform-Image"

    action {
      name            = "BuildPlatformImage"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.build_platform_image.name
      }
    }
  }

  stage {
    name = "Provision"

    action {
      name            = "ProvisionPipelines"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.provisioner.name
        EnvironmentVariables = jsonencode([
          {
            name  = "FORCE_DELETE_ALL_PIPELINES"
            value = "#{variables.FORCE_DELETE_ALL_PIPELINES}"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }
}
