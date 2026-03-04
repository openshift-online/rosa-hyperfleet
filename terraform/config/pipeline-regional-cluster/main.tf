data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Use target_alias (regional_id) directly — already unique per environment/CI run
  name_prefix    = var.target_alias
  account_suffix = substr(data.aws_caller_identity.current.account_id, -8, 8)

  # Resource naming: {name_prefix}-{resource-type}
  artifact_bucket_name   = "${local.name_prefix}-artifacts-${local.account_suffix}"
  codebuild_role_name    = "${local.name_prefix}-codebuild-role"
  codepipeline_role_name = "${local.name_prefix}-codepipeline-role"
  apply_project_name     = "${local.name_prefix}-apply"
  bootstrap_project_name = "${local.name_prefix}-bootstrap"
  pipeline_name          = "${local.name_prefix}-pipe"

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
          "logs:*",
          "ec2:*",
          "eks:*",
          "iam:*",
          "s3:*",
          "ecs:*",
          "kms:*",
          "apigateway:*",
          "iot:*",
          "rds:*",
          "secretsmanager:*",
          "elasticloadbalancing:*",
          "autoscaling:*",
          "cloudwatch:*",
          "tag:*"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::*:role/OrganizationAccountAccessRole"
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
          aws_codebuild_project.regional_apply.arn,
          aws_codebuild_project.regional_bootstrap.arn
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

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
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
resource "aws_codebuild_project" "regional_apply" {
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

    # GitHub repository in owner/name format
    environment_variable {
      name  = "GITHUB_REPOSITORY"
      value = var.github_repository
    }
    # Git branch to monitor for pipeline triggers
    environment_variable {
      name  = "GITHUB_BRANCH"
      value = var.github_branch
    }
    # AWS account ID where resources will be deployed
    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    # AWS region for deployment
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    # Human-readable alias for the target environment
    environment_variable {
      name  = "TARGET_ALIAS"
      value = var.target_alias
    }
    # Application code for resource tagging
    environment_variable {
      name  = "APP_CODE"
      value = var.app_code
    }
    # Service phase (dev/staging/prod)
    environment_variable {
      name  = "SERVICE_PHASE"
      value = var.service_phase
    }
    # Cost center for billing attribution
    environment_variable {
      name  = "COST_CENTER"
      value = var.cost_center
    }
    # Git repository URL for ArgoCD to sync
    environment_variable {
      name  = "REPOSITORY_URL"
      value = var.repository_url
    }
    # Git branch for ArgoCD to track
    environment_variable {
      name  = "REPOSITORY_BRANCH"
      value = var.repository_branch
    }
    # Target environment name (dev/staging/prod)
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.target_environment
    }
    # Enable bastion host for cluster access
    environment_variable {
      name  = "ENABLE_BASTION"
      value = var.enable_bastion ? "true" : "false"
    }
    environment_variable {
      name  = "PLATFORM_IMAGE"
      value = var.codebuild_image
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-regional-cluster/buildspec-provision-infra.yml"
  }
}

# CodeBuild Project - Bootstrap ArgoCD
resource "aws_codebuild_project" "regional_bootstrap" {
  name          = local.bootstrap_project_name
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    # GitHub repository in owner/name format
    environment_variable {
      name  = "GITHUB_REPOSITORY"
      value = var.github_repository
    }
    # Git branch to monitor for pipeline triggers
    environment_variable {
      name  = "GITHUB_BRANCH"
      value = var.github_branch
    }
    # AWS account ID where resources will be deployed
    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    # Human-readable alias for the target environment
    environment_variable {
      name  = "TARGET_ALIAS"
      value = var.target_alias
    }
    # AWS region for deployment
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    # Target environment name (dev/staging/prod)
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.target_environment
    }
    # Git repository URL for ArgoCD to sync
    environment_variable {
      name  = "REPOSITORY_URL"
      value = var.repository_url
    }
    # Git branch for ArgoCD to track
    environment_variable {
      name  = "REPOSITORY_BRANCH"
      value = var.repository_branch
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-regional-cluster/buildspec-bootstrap-argocd.yml"
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
resource "aws_codepipeline" "central_pipeline" {
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
          includes = ["deploy/${var.target_environment}/${var.target_region}/terraform/regional.json", "terraform/config/pipeline-regional-cluster/**"]
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
        ProjectName = aws_codebuild_project.regional_apply.name
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
        ProjectName = aws_codebuild_project.regional_bootstrap.name
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
