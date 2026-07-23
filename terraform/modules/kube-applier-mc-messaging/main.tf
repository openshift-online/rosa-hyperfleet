# =============================================================================
# kube-applier-mc-messaging Module
#
# Provisions the MC-side messaging resources for the two-way SNS/SQS
# notification system between the hyperfleet-operator (RC account) and
# kube-applier-aws (MC account).
#
# Specs path  (RC → MC): The RC account publishes to an SNS topic when it
#   writes a new desire document. This module creates the SQS queue in the MC
#   account that receives those notifications. kube-applier polls this queue
#   instead of DynamoDB Streams.
#
# Status path (MC → RC): kube-applier publishes to an SNS topic in the MC
#   account after writing a status document. This module creates that topic.
#   The RC account provisions the corresponding SQS queues and subscriptions.
#
# Resource naming:
#   Specs SQS queue:   ${mc_name}-specs-notifications  (MC account)
#   Status SNS topic:  ${mc_name}-status-notifications (MC account)
#   KMS key alias:     alias/${mc_name}-kube-applier-messaging
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy         = "terraform"
      Module            = "kube-applier-mc-messaging"
      ManagementCluster = var.mc_name
    }
  )

  # IAM role ARN for the kube-applier pod in this MC account
  kube_applier_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.mc_name}-kube-applier"
}

# =============================================================================
# KMS Key — shared encryption key for MC-side messaging resources
# =============================================================================

resource "aws_kms_key" "messaging" {
  description             = "KMS key for ${var.mc_name} kube-applier messaging (SQS + SNS)"
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
        # SNS must be able to encrypt/decrypt when delivering messages to SQS
        Sid    = "AllowSNSDelivery"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        # SQS must be able to use the key when the queue is encrypted
        Sid    = "AllowSQS"
        Effect = "Allow"
        Principal = {
          Service = "sqs.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.mc_name}-kube-applier-messaging"
  })
}

resource "aws_kms_alias" "messaging" {
  name          = "alias/${var.mc_name}-kube-applier-messaging"
  target_key_id = aws_kms_key.messaging.key_id
}

# =============================================================================
# Specs SQS Queue (specs path receiver — RC SNS → MC SQS)
#
# kube-applier polls this queue for notifications that the operator has written
# a new desire document. On receipt, it immediately re-queues the affected
# documentID for reconciliation instead of waiting for the 5-minute safety poll.
# =============================================================================

resource "aws_sqs_queue" "specs" {
  name                       = "${var.mc_name}-specs-notifications"
  kms_master_key_id          = aws_kms_key.messaging.id
  message_retention_seconds  = 300 # 5 minutes — notifications are ephemeral wake-up signals
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 20 # long-polling

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-specs-notifications"
    Direction = "specs-rc-to-mc"
  })
}

# Allow the RC-account specs SNS topic to deliver messages to this queue.
# AWS requires both an identity-based policy on the SNS topic AND a
# resource-based policy on the SQS queue for cross-account delivery.
resource "aws_sqs_queue_policy" "specs" {
  queue_url = aws_sqs_queue.specs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowRCSpecsSNSDelivery"
      Effect = "Allow"
      Principal = {
        Service = "sns.amazonaws.com"
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.specs.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = var.rc_specs_sns_topic_arn
        }
      }
    }]
  })
}

# =============================================================================
# Status SNS Topic (status path sender — MC SNS → RC SQS)
#
# kube-applier publishes a lightweight notification here after successfully
# writing a status document. The RC account subscribes its per-replica operator
# SQS queues to this topic for cross-account delivery.
# =============================================================================

resource "aws_sns_topic" "status" {
  name              = "${var.mc_name}-status-notifications"
  kms_master_key_id = aws_kms_key.messaging.id

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-status-notifications"
    Direction = "status-mc-to-rc"
  })
}

# Allow the kube-applier pod role to publish status notifications.
# The RC account (as subscriber) is also given sns:Subscribe so that the
# subscription created in the RC account's kube-applier-rc-messaging module
# can be confirmed without requiring manual approval.
resource "aws_sns_topic_policy" "status" {
  arn = aws_sns_topic.status.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowKubeApplierPublish"
        Effect = "Allow"
        Principal = {
          AWS = local.kube_applier_role_arn
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.status.arn
      },
      {
        # Allow the RC account to create cross-account SQS subscriptions.
        # Without this, aws_sns_topic_subscription from the RC module would
        # fail with an AuthorizationError even if the SQS queue policy permits
        # delivery.
        Sid    = "AllowRCAccountSubscribe"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.rc_aws_account_id}:root"
        }
        Action = [
          "sns:Subscribe",
          "sns:Unsubscribe",
        ]
        Resource = aws_sns_topic.status.arn
      },
    ]
  })
}

# =============================================================================
# IAM: extend kube-applier role with messaging permissions
#
# The kube-applier role is created by the kube-applier module. We add a
# supplementary inline policy here so that all messaging IAM is co-located
# with the messaging infrastructure rather than scattered across modules.
# =============================================================================

resource "aws_iam_role_policy" "kube_applier_messaging" {
  name = "${var.mc_name}-kube-applier-messaging"
  role = "${var.mc_name}-kube-applier"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SpecsQueueReceive"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.specs.arn
      },
      {
        Sid    = "StatusTopicPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish",
        ]
        Resource = aws_sns_topic.status.arn
      },
      {
        Sid    = "MessagingKMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = aws_kms_key.messaging.arn
      },
    ]
  })
}

# =============================================================================
# SSM Parameters — surface queue URL and topic ARN for app config
# =============================================================================

resource "aws_ssm_parameter" "specs_queue_url" {
  name        = "/${var.mc_name}/messaging/specs-queue-url"
  description = "SQS queue URL for specs change notifications (RC → MC)"
  type        = "String"
  value       = aws_sqs_queue.specs.url

  tags = merge(local.common_tags, {
    Name = "${var.mc_name}-specs-queue-url"
  })
}

resource "aws_ssm_parameter" "status_topic_arn" {
  name        = "/${var.mc_name}/messaging/status-topic-arn"
  description = "SNS topic ARN for status change notifications (MC → RC)"
  type        = "String"
  value       = aws_sns_topic.status.arn

  tags = merge(local.common_tags, {
    Name = "${var.mc_name}-status-topic-arn"
  })
}
