# =============================================================================
# ALB Access Logs (FedRAMP AU-09, AU-11)
#
# S3 bucket for ALB access logs. SSE-S3 (AES256) is used because the ELB
# service cannot write to SSE-KMS buckets — it does not call
# kms:GenerateDataKey and access is denied at the S3 layer.
#
# Retention (AU-11): configurable hot/cold periods.
#   Default: 90 days Standard (FedRAMP Moderate floor), then Glacier,
#            expire after 1 year total.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_elb_service_account" "current" {}

# -----------------------------------------------------------------------------
# S3 Bucket
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "access_logs" {
  bucket = "${var.regional_id}-sre-alb-logs"

  tags = {
    Name = "${var.regional_id}-sre-alb-logs"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "access-log-retention"
    status = "Enabled"

    transition {
      days          = var.access_logs_standard_days
      storage_class = "GLACIER"
    }

    expiration {
      days = var.access_logs_standard_days + var.access_logs_glacier_days
    }
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Bucket Policy
#
# ELB service account must be able to put objects. KMS encryption is applied
# by S3 after delivery, so the ELB service does not need kms:GenerateDataKey.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ELBAccessLogs"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.current.arn
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.access_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid    = "DenyNonTLS"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "s3:*"
        Resource = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}
