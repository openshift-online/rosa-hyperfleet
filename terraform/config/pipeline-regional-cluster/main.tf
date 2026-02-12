provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Create unique names per regional pipeline using target_alias
  # Fallback to region if alias not provided
  name_suffix = var.target_alias != "" ? var.target_alias : var.region

  # Use hash-based naming for all resources to avoid length limits
  # Hash of full alias ensures uniqueness while keeping names short
  resource_hash = substr(md5("regional-${local.name_suffix}-${data.aws_caller_identity.current.account_id}"), 0, 12)
  account_suffix = substr(data.aws_caller_identity.current.account_id, -8, 8)

  # Resource naming patterns (all under 32 chars)
  artifact_bucket_name = "rc-${local.resource_hash}-${local.account_suffix}"  # 24 chars
  github_connection_name = "rc-gh-${local.resource_hash}"  # 18 chars
  codebuild_role_name = "rc-cb-${local.resource_hash}"  # 18 chars
  codepipeline_role_name = "rc-cp-${local.resource_hash}"  # 18 chars
  validate_project_name = "rc-val-${local.resource_hash}"  # 19 chars
  apply_project_name = "rc-app-${local.resource_hash}"  # 19 chars
  bootstrap_project_name = "rc-boot-${local.resource_hash}"  # 21 chars
  pipeline_name = "rc-pipe-${local.resource_hash}"  # 20 chars
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
          aws_codebuild_project.regional_validate.arn,
          aws_codebuild_project.regional_apply.arn,
          aws_codebuild_project.regional_bootstrap.arn
        ]
      }
    ]
  })
}

# S3 Bucket for Artifacts
resource "aws_s3_bucket" "pipeline_artifact" {
  bucket = local.artifact_bucket_name

  timeouts {
    create = "30s"  # Fail fast if bucket creation hangs (explicit names should be instant)
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

# CodeBuild Project - Validate
resource "aws_codebuild_project" "regional_validate" {
  name          = local.validate_project_name
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "GITHUB_REPO_OWNER"
      value = var.github_repo_owner
    }
    environment_variable {
      name  = "GITHUB_REPO_NAME"
      value = var.github_repo_name
    }
    environment_variable {
      name  = "GITHUB_BRANCH"
      value = var.github_branch
    }
    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    environment_variable {
      name  = "TARGET_ALIAS"
      value = var.target_alias
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-regional-cluster/buildspec-validate.yml"
  }
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
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "GITHUB_REPO_OWNER"
      value = var.github_repo_owner
    }
    environment_variable {
      name  = "GITHUB_REPO_NAME"
      value = var.github_repo_name
    }
    environment_variable {
      name  = "GITHUB_BRANCH"
      value = var.github_branch
    }
    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    environment_variable {
      name  = "TARGET_ALIAS"
      value = var.target_alias
    }
    environment_variable {
      name  = "APP_CODE"
      value = var.app_code
    }
    environment_variable {
      name  = "SERVICE_PHASE"
      value = var.service_phase
    }
    environment_variable {
      name  = "COST_CENTER"
      value = var.cost_center
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-regional-cluster/buildspec-apply.yml"
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
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "GITHUB_REPO_OWNER"
      value = var.github_repo_owner
    }
    environment_variable {
      name  = "GITHUB_REPO_NAME"
      value = var.github_repo_name
    }
    environment_variable {
      name  = "GITHUB_BRANCH"
      value = var.github_branch
    }
    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_id
    }
    environment_variable {
      name  = "TARGET_REGION"
      value = var.target_region
    }
    environment_variable {
      name  = "TARGET_ALIAS"
      value = var.target_alias
    }
    environment_variable {
      name  = "TARGET_ENVIRONMENT"
      value = var.target_environment
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-regional-cluster/buildspec-bootstrap.yml"
  }
}

# CodePipeline
resource "aws_codepipeline" "central_pipeline" {
  name          = local.pipeline_name
  role_arn      = aws_iam_role.codepipeline_role.arn
  pipeline_type = "V2"

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
          includes = ["deploy/**", "terraform/config/pipeline-regional-cluster/**", "terraform/config/pipeline-management-cluster/**"]
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
        FullRepositoryId = "${var.github_repo_owner}/${var.github_repo_name}"
        BranchName       = var.github_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Validate"

    action {
      name             = "ValidateAndPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["validate_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.regional_validate.name
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
      input_artifacts  = ["validate_output"]
      output_artifacts = ["apply_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.regional_apply.name
      }
    }
  }

  stage {
    name = "Bootstrap"

    action {
      name             = "BootstrapArgoCD"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["apply_output"]
      output_artifacts = ["bootstrap_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.regional_bootstrap.name
      }
    }
  }
}
