# =============================================================================
# IAM Roles for ZOA Lambda Architecture
#
# Lambda-based ZOA uses STS AssumeRole (not Pod Identity) for all AWS access:
# - Uploader role: Lambda assumes this to generate scoped S3 creds for async Jobs
# - Data Access role: MC Lambdas assume this for cross-account DynamoDB+S3 access
# - AWS read/write roles: Defined in zoa-lambda module (per-VPC, same account)
# =============================================================================

locals {
  rc_zoa_lambda_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.regional_id}-zoa-lambda"
}

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
    Statement = concat(
      [{
        Sid       = "SameAccountLambdas"
        Effect    = "Allow"
        Principal = { AWS = local.rc_zoa_lambda_role_arn }
        Action    = "sts:AssumeRole"
      }],
      length(var.mc_zoa_lambda_role_arns) > 0 ? [{
        Sid       = "CrossAccountMCLambdas"
        Effect    = "Allow"
        Principal = { AWS = var.mc_zoa_lambda_role_arns }
        Action    = "sts:AssumeRole"
      }] : [],
    )
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
      Sid       = "CrossAccountMCLambdas"
      Effect    = "Allow"
      Principal = { AWS = var.mc_zoa_lambda_role_arns }
      Action    = "sts:AssumeRole"
    }]
  })

  lifecycle {
    precondition {
      condition     = length(var.mc_zoa_lambda_role_arns) > 0
      error_message = "management_clusters must resolve to at least one MC account_id before RC ZOA apply (pipeline-regional-cluster-inputs management_clusters_info)."
    }
  }

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
        aws_dynamodb_table.boundary_sessions.arn,
        "${aws_dynamodb_table.boundary_sessions.arn}/index/*",
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

