# =============================================================================
# CloudTrail Module — FedRAMP AU-12 Audit Record Generation
#
# Creates a multi-region CloudTrail trail that captures all management-plane
# API calls across all AWS services (IAM, DynamoDB, RDS, KMS, EKS, S3, etc.)
# and delivers them to an encrypted S3 bucket with 365-day retention and
# optional CloudWatch Logs integration.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  fips_regions         = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "us-gov-east-1", "us-gov-west-1"]
  log_retention_days   = 365
  cloudtrail_trail_arn = "arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:trail/${var.cluster_id}-cloudtrail"
}

# =============================================================================
# KMS Key for CloudTrail S3 Encryption
# =============================================================================

resource "aws_kms_key" "cloudtrail" {
  description             = "KMS key for CloudTrail S3 bucket encryption (FedRAMP AU-09/AU-12)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudTrail"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceArn" = local.cloudtrail_trail_arn
          }
        }
      },
      {
        Sid    = "AllowCloudTrailDecrypt"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = local.cloudtrail_trail_arn
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.cluster_id}-cloudtrail"
  }
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/${var.cluster_id}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

# =============================================================================
# S3 Bucket for CloudTrail Logs
# =============================================================================

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.cluster_id}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.environment == "ephemeral"

  tags = {
    Name = "${var.cluster_id}-cloudtrail"
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudtrail.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: retain 365 days online, expire after 3 years total (FedRAMP AU-11)
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "cloudtrail-retention"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      days = 1095 # 3 years total (FedRAMP AU-11 requirement)
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = local.cloudtrail_trail_arn
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.cloudtrail_trail_arn
          }
        }
      }
    ]
  })
}

# =============================================================================
# CloudWatch Log Group for CloudTrail (real-time analysis via AU-06)
# =============================================================================

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.cluster_id}"
  retention_in_days = local.log_retention_days

  tags = {
    Name = "${var.cluster_id}-cloudtrail"
  }
}

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name = "${var.cluster_id}-cloudtrail-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceArn"     = local.cloudtrail_trail_arn
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  role = aws_iam_role.cloudtrail_cloudwatch.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}

# =============================================================================
# CloudTrail Trail
# =============================================================================

resource "aws_cloudtrail" "main" {
  name                          = "${var.cluster_id}-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.cloudtrail.arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn

  # Capture management events (read + write)
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # Capture S3 data events for audit buckets
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.cloudtrail.arn}/"]
    }
  }

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_cloudwatch_log_group.cloudtrail,
    aws_iam_role_policy.cloudtrail_cloudwatch,
  ]

  tags = {
    Name = "${var.cluster_id}-cloudtrail"
  }
}
