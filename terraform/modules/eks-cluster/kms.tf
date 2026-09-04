# =============================================================================
# KMS Configuration for EKS Secrets Encryption
#
# Creates customer-managed KMS key for encrypting EKS secrets at rest.
# Includes proper IAM policies for EKS service access and key management.
# =============================================================================

# -----------------------------------------------------------------------------
# KMS Key for EKS Secrets
#
# Customer-managed key with automatic rotation enabled for security.
# Allows EKS service to encrypt/decrypt secrets while maintaining
# administrative control over the encryption key.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "eks_secrets" {
  description             = "KMS key for EKS cluster secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "EnableEKSAccess"
        Effect = "Allow"
        Principal = {
          AWS = [
            aws_iam_role.eks_cluster.arn
          ]
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.cluster_id}-eks-secrets"
  })
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.cluster_id}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}
