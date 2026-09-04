# =============================================================================
# Loki Infrastructure Module
#
# Creates S3 bucket, KMS key, IAM role, and EKS Pod Identity association
# for Loki log storage. All Loki components share a single writer role
# via one ServiceAccount (Distributed deployment mode).
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  bucket_name = "${var.cluster_id}-loki-logs-${data.aws_caller_identity.current.account_id}"
  writer_role = "${var.cluster_id}-loki-writer"

  fips_regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "us-gov-east-1", "us-gov-west-1"]
  use_fips     = contains(local.fips_regions, data.aws_region.current.region)
  s3_endpoint  = local.use_fips ? "s3-fips.${data.aws_region.current.region}.amazonaws.com" : "s3.${data.aws_region.current.region}.amazonaws.com"

  common_tags = merge(
    var.tags,
    {
      function = "observability"
      module   = "loki-infrastructure"
    }
  )
}

# =============================================================================
# KMS Key for S3 Encryption (FedRAMP Requirement)
# =============================================================================

resource "aws_kms_key" "loki" {
  description             = "KMS key for Loki logs S3 bucket encryption"
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
        Sid    = "AllowLokiWriterRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.loki_writer.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-loki"
  })
}

resource "aws_kms_alias" "loki" {
  name          = "alias/${var.cluster_id}-loki"
  target_key_id = aws_kms_key.loki.key_id
}

# =============================================================================
# S3 Bucket for Loki Log Storage
# =============================================================================

resource "aws_s3_bucket" "loki" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.loki.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket = aws_s3_bucket.loki.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    expiration {
      days = var.logs_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# =============================================================================
# IAM Role for Loki Writer (Distributor, Ingester, Compactor)
# =============================================================================

resource "aws_iam_role" "loki_writer" {
  name = local.writer_role

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = local.writer_role
  })
}

resource "aws_iam_role_policy" "loki_s3_write" {
  name = "loki-s3-write"
  role = aws_iam_role.loki_writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.loki.arn
      },
      {
        Sid    = "S3ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.loki.arn}/*"
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.loki.arn
      }
    ]
  })
}

# =============================================================================
# EKS Pod Identity Association
#
# The grafana/loki Helm chart in Distributed mode uses a single
# ServiceAccount shared by all components (distributor, ingester, querier,
# compactor, etc.). All need S3 write access since the compactor deletes
# objects and ingesters flush chunks.
# =============================================================================

resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.loki_namespace
  service_account = var.loki_service_account
  role_arn        = aws_iam_role.loki_writer.arn

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-loki"
  })
}
