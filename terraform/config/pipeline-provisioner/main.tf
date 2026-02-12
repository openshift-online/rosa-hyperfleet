provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Use shared GitHub Connection (created in bootstrap-pipeline)
data "aws_codestarconnections_connection" "github" {
  arn = var.github_connection_arn
}

# IAM Role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = "pipeline-provisioner-codebuild"

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
        Resource = "*"
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
          "codepipeline:*",
          "codebuild:*",
          "codestar-connections:*",
          "iam:*",
          "s3:*"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Role for CodePipeline
resource "aws_iam_role" "codepipeline_role" {
  name = "pipeline-provisioner-pipeline"

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
        Resource = aws_codebuild_project.provisioner.arn
      }
    ]
  })
}

# S3 Bucket for Artifacts
resource "aws_s3_bucket" "pipeline_artifact" {
  bucket = "pipeline-provisioner-artifacts-${data.aws_caller_identity.current.account_id}"
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

# CodeBuild Project - Pipeline Provisioner
resource "aws_codebuild_project" "provisioner" {
  name          = "pipeline-provisioner"
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
      name  = "TARGET_ENVIRONMENT"
      value = var.environment
    }
    environment_variable {
      name  = "GITHUB_CONNECTION_ARN"
      value = data.aws_codestarconnections_connection.github.arn
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-provisioner/buildspec.yml"
  }
}

# CodePipeline - Pipeline Provisioner
resource "aws_codepipeline" "provisioner" {
  name           = "pipeline-provisioner"
  role_arn       = aws_iam_role.codepipeline_role.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED"  # Prevent parallel executions that could cause lock conflicts

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
            "deploy/${var.environment}/*/terraform/regional.json",
            "deploy/${var.environment}/*/terraform/management/*.json",
            "terraform/config/pipeline-regional-cluster/**",
            "terraform/config/pipeline-management-cluster/**"
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
        FullRepositoryId = "${var.github_repo_owner}/${var.github_repo_name}"
        BranchName       = var.github_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Provision"

    action {
      name             = "ProvisionPipelines"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["provision_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.provisioner.name
      }
    }
  }
}
