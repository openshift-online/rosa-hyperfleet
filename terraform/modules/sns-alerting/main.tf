# =============================================================================
# SNS Alerting Module — Phase 2 Alert Fan-Out
#
# Creates an encrypted SNS topic for alert distribution, an SSM parameter
# storing the topic ARN for reference, and an IAM role for Alertmanager
# to publish alerts via EKS Pod Identity using the native sns_configs receiver.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      function = "observability"
      module   = "sns-alerting"
    }
  )
}

# =============================================================================
# KMS Key for SNS Topic Encryption
# =============================================================================

resource "aws_kms_key" "sns_alerts" {
  description             = "KMS key for SNS alert topic encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = 90

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
        Sid    = "AllowSNS"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name      = "${var.regional_id}-sns-alerts"
    Module    = "sns-alerting"
    ManagedBy = "terraform"
  })
}

resource "aws_kms_alias" "sns_alerts" {
  name          = "alias/${var.regional_id}-sns-alerts"
  target_key_id = aws_kms_key.sns_alerts.key_id
}

# =============================================================================
# SNS Topic
# =============================================================================

resource "aws_sns_topic" "alerts" {
  name              = "${var.regional_id}-alerts"
  kms_master_key_id = aws_kms_key.sns_alerts.id

  tags = merge(local.common_tags, {
    Name      = "${var.regional_id}-alerts"
    Module    = "sns-alerting"
    ManagedBy = "terraform"
  })
}

# =============================================================================
# SSM Parameter — Topic ARN for reference
# =============================================================================

resource "aws_ssm_parameter" "sns_topic_arn" {
  name        = "/${var.regional_id}/alerting/sns-topic-arn"
  description = "SNS topic ARN for alert fan-out"
  type        = "String"
  value       = aws_sns_topic.alerts.arn

  tags = merge(local.common_tags, {
    Name      = "${var.regional_id}-alerting-sns-topic-arn"
    Module    = "sns-alerting"
    ManagedBy = "terraform"
  })
}

# =============================================================================
# IAM Role for Alertmanager
#
# Grants Alertmanager permission to publish alerts to the SNS topic via its
# native sns_configs receiver with SigV4 authentication.
# =============================================================================

resource "aws_iam_role" "alertmanager" {
  name        = "${var.regional_id}-alertmanager-sns"
  description = "IAM role for Alertmanager SNS publish permission"

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

  tags = merge(local.common_tags, {
    Name      = "${var.regional_id}-alertmanager-sns-role"
    Module    = "sns-alerting"
    ManagedBy = "terraform"
  })
}

resource "aws_iam_role_policy" "alertmanager_sns" {
  name = "${var.regional_id}-alertmanager-sns-policy"
  role = aws_iam_role.alertmanager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.alerts.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext"
        ]
        Resource = [
          aws_kms_key.sns_alerts.arn
        ]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "alertmanager" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.alertmanager_namespace
  service_account = var.alertmanager_service_account
  role_arn        = aws_iam_role.alertmanager.arn

  tags = merge(local.common_tags, {
    Name      = "${var.regional_id}-alertmanager-sns-pod-identity"
    Module    = "sns-alerting"
    ManagedBy = "terraform"
  })
}
