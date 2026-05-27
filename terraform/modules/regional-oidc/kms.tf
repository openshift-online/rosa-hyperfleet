resource "aws_kms_key" "oidc" {
  description             = "KMS key for regional OIDC S3 bucket encryption"
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
        Sid    = "AllowCloudFrontDecrypt"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.oidc.arn
          }
        }
      },
      {
        Sid    = "AllowManagementClusterUseViaS3"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:PrincipalOrgPaths"            = var.mc_ou_path
            "aws:PrincipalArn"                 = "arn:*:iam::*:role/*-hypershift-operator"
            "kms:EncryptionContext:aws:s3:arn" = "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}*"
          }
          StringEquals = {
            "kms:ViaService" = "s3.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.regional_id}-oidc"
  }
}

resource "aws_kms_alias" "oidc" {
  name          = "alias/${var.regional_id}-oidc"
  target_key_id = aws_kms_key.oidc.key_id
}
