# =============================================================================
# KMS Key for ZOA Encryption
# =============================================================================
# Encrypts DynamoDB table and S3 bucket contents

resource "aws_kms_key" "zoa" {
  description             = "KMS key for ZOA outputs encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-zoa"
      Component = "zoa"
    }
  )
}

resource "aws_kms_alias" "zoa" {
  name          = local.kms_alias
  target_key_id = aws_kms_key.zoa.key_id
}

resource "aws_kms_key_policy" "zoa" {
  key_id = aws_kms_key.zoa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowPlatformAPIAccess"
        Effect = "Allow"
        Principal = {
          AWS = var.platform_api_role_arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowJobRoleAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.job.arn
        }
        Action = [
          "kms:GenerateDataKey",
        ]
        Resource = "*"
      },
    ]
  })
}

data "aws_caller_identity" "current" {}
