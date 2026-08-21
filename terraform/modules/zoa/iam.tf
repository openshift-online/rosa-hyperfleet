# =============================================================================
# IAM Policies for ZOA
#
# Platform API policies attach to the existing role (owned by authz module).
# Job role is self-contained (runs on MCs with its own SA).
# =============================================================================

# =============================================================================
# Platform API - Additional policies on existing role
# =============================================================================

resource "aws_iam_role_policy" "platform_api_zoa_dynamodb" {
  name = "${var.regional_id}-zoa-dynamodb"
  role = var.platform_api_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
        ]
        Resource = [
          aws_dynamodb_table.executions.arn,
          "${aws_dynamodb_table.executions.arn}/index/*",
          aws_dynamodb_table.audit_log.arn,
          "${aws_dynamodb_table.audit_log.arn}/index/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "platform_api_zoa_s3" {
  name = "${var.regional_id}-zoa-s3"
  role = var.platform_api_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.outputs.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.outputs.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "platform_api_zoa_kms" {
  name = "${var.regional_id}-zoa-kms"
  role = var.platform_api_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = aws_kms_key.zoa.arn
      },
    ]
  })
}

# =============================================================================
# Job Role - Self-contained for TA jobs running on MCs
# =============================================================================

resource "aws_iam_role" "job" {
  name        = "${var.regional_id}-zoa-job"
  description = "IAM role for ZOA Trusted Action jobs running on Management Clusters"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.regional_id}-zoa-job-role"
    }
  )
}

resource "aws_iam_role_policy" "job_s3" {
  name = "${var.regional_id}-zoa-job-s3-upload"
  role = aws_iam_role.job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.outputs.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "job_kms" {
  name = "${var.regional_id}-zoa-job-kms"
  role = aws_iam_role.job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "kms:GenerateDataKey"
        Resource = aws_kms_key.zoa.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "job_aws_api_read" {
  name = "${var.regional_id}-zoa-job-aws-api-read"
  role = aws_iam_role.job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:ListClusters",
          "eks:DescribeCluster",
          "ec2:DescribeVpcEndpoints",
        ]
        Resource = "*"
      },
    ]
  })
}

# Pod Identity association for ZOA jobs running on the RC itself.
# The RC is in the same account as this module so we can create it directly.
resource "aws_eks_pod_identity_association" "job_rc" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-kube-sa"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-job-rc-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "job_rc_aws_read" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-aws-read"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-aws-read-rc-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "job_rc_aws_write" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-aws-write"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-aws-write-rc-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "job_rc_breakglass_read" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-breakglass-read"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-breakglass-read-rc-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "job_rc_breakglass_write" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-breakglass-write"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-breakglass-write-rc-pod-identity"
  })
}

# NOTE: Pod Identity associations for ZOA jobs on MCs are created by the
# zoa-job-pod-identity module in the management-cluster Terraform config,
# because associations must be in the same AWS account as the EKS cluster.

# =============================================================================
# Uploader Role - Assumed by Lambda (via STS) for scoped S3 upload credentials
# =============================================================================
# The Lambda execution role assumes this role with a session policy that restricts
# writes to a specific execution prefix: s3://bucket/executions/{execID}/*
# This ensures compromised Job Pods can only write their own output.

resource "aws_iam_role" "uploader" {
  name        = "${var.regional_id}-zoa-uploader"
  description = "STS-assumed role for ZOA async Job S3 uploads (scoped per-execution)"

  # Two trust statements:
  # 1. Same-account: RC Lambda assumes this for RC async Jobs
  # 2. Cross-account: MC Lambdas assume this for MC async Jobs (S3 bucket is in RC)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SameAccountLambdas"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::*:role/*-zoa-lambda"
          }
        }
      },
      {
        Sid    = "CrossAccountMCLambdas"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = "sts:AssumeRole"
        Condition = {
          "ForAnyValue:StringLike" = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
          }
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::*:role/*-zoa-lambda"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-uploader-role"
  })
}

resource "aws_iam_role_policy" "uploader_s3" {
  name = "${var.regional_id}-zoa-uploader-s3"
  role = aws_iam_role.uploader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:PutObjectTagging",
      ]
      Resource = "${aws_s3_bucket.outputs.arn}/executions/*"
    }]
  })
}

resource "aws_iam_role_policy" "uploader_kms" {
  name = "${var.regional_id}-zoa-uploader-kms"
  role = aws_iam_role.uploader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "kms:GenerateDataKey"
      Resource = aws_kms_key.zoa.arn
    }]
  })
}

# =============================================================================
# Data Access Role (cross-account)
# =============================================================================
# MC Lambdas cannot access RC DynamoDB/S3 directly because:
# 1. DynamoDB resolves table names to the caller's account. DescribeTable and
#    data-plane operations all fail with ResourceNotFoundException when called
#    from a different account — even with resource-based policies — because the
#    SDK version (v1.60.x) does not support the TableArn parameter needed for
#    automatic cross-account routing.
# 2. S3 HeadBucket also fails cross-account without explicit credentials.
#
# Solution: MC Lambdas assume this role (in the RC account) to obtain temporary
# credentials that target RC-local DynamoDB tables and the S3 bucket.

resource "aws_iam_role" "data_access" {
  name        = "${var.regional_id}-zoa-data-access"
  description = "Cross-account role for MC Lambda DynamoDB+S3 access to RC data layer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = "sts:AssumeRole"
      Condition = {
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
        }
        ArnLike = {
          "aws:PrincipalArn" = "arn:aws:iam::*:role/*-zoa-lambda"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-data-access-role"
  })
}

resource "aws_iam_role_policy" "data_access_dynamodb" {
  name = "${var.regional_id}-zoa-data-access-dynamodb"
  role = aws_iam_role.data_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
        "dynamodb:DescribeTable",
      ]
      Resource = [
        aws_dynamodb_table.executions.arn,
        "${aws_dynamodb_table.executions.arn}/index/*",
        aws_dynamodb_table.audit_log.arn,
        "${aws_dynamodb_table.audit_log.arn}/index/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "data_access_s3" {
  name = "${var.regional_id}-zoa-data-access-s3"
  role = aws_iam_role.data_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectTagging",
        ]
        Resource = "${aws_s3_bucket.outputs.arn}/executions/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:HeadBucket",
        ]
        Resource = aws_s3_bucket.outputs.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "data_access_kms" {
  name = "${var.regional_id}-zoa-data-access-kms"
  role = aws_iam_role.data_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      Resource = aws_kms_key.zoa.arn
    }]
  })
}
