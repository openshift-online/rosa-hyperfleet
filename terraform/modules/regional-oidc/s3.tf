resource "aws_s3_bucket" "oidc" {
  bucket        = local.bucket_name
  force_destroy = false

  tags = {
    Name = local.bucket_name
  }
}

resource "aws_s3_bucket_versioning" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.oidc.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  depends_on = [aws_s3_bucket_public_access_block.oidc]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyInsecureTransport"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.oidc.arn,
          "${aws_s3_bucket.oidc.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.oidc.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.oidc.arn
          }
        }
      },
      {
        Sid    = "AllowManagementClusterWrite"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.oidc.arn,
          "${aws_s3_bucket.oidc.arn}/*",
        ]
        Condition = {
          StringLike = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
            "aws:PrincipalArn"      = "arn:*:iam::*:role/*-hypershift-operator"
          }
        }
      },
    ]
  })
}