# =============================================================================
# kube-applier-rc-messaging Module
#
# Provisions the RC-side messaging resources for the two-way SNS/SQS
# notification system between the hyperfleet-operator (RC account) and
# kube-applier-aws (MC account).
#
# Specs path  (RC → MC): The hyperfleet-operator publishes to an SNS topic in
#   the RC account after writing a desire document. This module creates that
#   topic and subscribes the MC-side specs SQS queue (mc_specs_queue_arn) to
#   it, forming the cross-account delivery link.
#
# Status path (MC → RC): kube-applier publishes status notifications to an SNS
#   topic in the MC account. This module creates one SQS queue per operator
#   replica in the RC account and subscribes each to the MC status SNS topic
#   (mc_status_sns_topic_arn). Each operator pod drains its own queue.
#
# Resource naming:
#   Specs SNS topic:        ${mc_name}-specs-notifications  (RC account)
#   Status SQS queues:      ${rc_id}-hyperfleet-operator-{0..N-1} (RC account)
#   KMS key alias:          alias/${mc_name}-kube-applier-messaging
#
# Incremental IAM pattern:
#   Like the existing ${mc_name}-dynamodb-access policy, this module attaches
#   a per-MC inline policy (${mc_name}-messaging-access) to the shared
#   ${rc_id}-hyperfleet-operator role. Each MC pipeline run adds its own
#   policy, so parallel per-MC state files never collide.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy         = "terraform"
      Module            = "kube-applier-rc-messaging"
      ManagementCluster = var.mc_name
    }
  )

  # Ordinal indices for the operator replica queues (0-based)
  replica_indices = range(var.operator_replica_count)

  # IAM role for the hyperfleet-operator (RC account, shared across all MCs)
  hyperfleet_operator_role_name = "${var.rc_id}-hyperfleet-operator"
}

# =============================================================================
# KMS Key — shared encryption key for RC-side messaging resources (per MC)
# =============================================================================

resource "aws_kms_key" "messaging" {
  description             = "KMS key for ${var.mc_name} kube-applier messaging (SNS + SQS) in RC account"
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
        # SQS must be able to use the key
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
# Specs SNS Topic (specs path sender — RC SNS → MC SQS)
#
# The hyperfleet-operator publishes a lightweight notification here after
# writing an ApplyDesire or ReadDesire document. The cross-account subscription
# below delivers that notification to the MC-side SQS queue.
# =============================================================================

resource "aws_sns_topic" "specs" {
  name              = "${var.mc_name}-specs-notifications"
  kms_master_key_id = aws_kms_key.messaging.id

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-specs-notifications"
    Direction = "specs-rc-to-mc"
  })
}

# Allow the hyperfleet-operator pod role to publish specs notifications.
# Also allow the MC account to confirm the cross-account SQS subscription.
resource "aws_sns_topic_policy" "specs" {
  arn = aws_sns_topic.specs.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowHyperfleetOperatorPublish"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.hyperfleet_operator_role_name}"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.specs.arn
      },
      {
        # The SNS subscription is created from the RC account (this module),
        # targeting the MC SQS queue. AWS auto-confirms SQS subscriptions, so
        # no MC-account confirmation action is needed here.
        Sid    = "AllowSNSToDeliverToSQS"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.specs.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

# Cross-account SNS→SQS subscription: RC specs topic → MC specs queue.
# AWS auto-confirms SQS subscriptions, so no ConfirmSubscription step is needed.
resource "aws_sns_topic_subscription" "specs_to_mc_queue" {
  topic_arn = aws_sns_topic.specs.arn
  protocol  = "sqs"
  endpoint  = var.mc_specs_queue_arn

  # Raw delivery passes the JSON notification body directly without the SNS
  # envelope wrapper, simplifying parsing in the kube-applier consumer.
  raw_message_delivery = true
}

# =============================================================================
# Status SQS Queues (status path receiver — MC SNS → RC SQS)
#
# One queue per hyperfleet-operator pod replica. Each pod polls only its own
# queue (named after its hostname, e.g. hyperfleet-operator-2), eliminating
# competing-consumer problems and making queue drain deterministic on scale-down.
# =============================================================================

resource "aws_sqs_queue" "status" {
  count = var.operator_replica_count

  name                       = "${var.rc_id}-hyperfleet-operator-${count.index}"
  kms_master_key_id          = aws_kms_key.messaging.id
  message_retention_seconds  = 300 # 5 minutes — notifications are ephemeral wake-up signals
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 20 # long-polling

  tags = merge(local.common_tags, {
    Name      = "${var.rc_id}-hyperfleet-operator-${count.index}"
    Direction = "status-mc-to-rc"
    Replica   = tostring(count.index)
  })
}

# Allow the MC-account status SNS topic to deliver messages to each queue.
resource "aws_sqs_queue_policy" "status" {
  count     = var.operator_replica_count
  queue_url = aws_sqs_queue.status[count.index].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowMCStatusSNSDelivery"
      Effect = "Allow"
      Principal = {
        Service = "sns.amazonaws.com"
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.status[count.index].arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = var.mc_status_sns_topic_arn
        }
      }
    }]
  })
}

# Cross-account SNS→SQS subscriptions: MC status topic → each RC operator queue.
resource "aws_sns_topic_subscription" "status_to_rc_queues" {
  count = var.operator_replica_count

  topic_arn            = var.mc_status_sns_topic_arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.status[count.index].arn
  raw_message_delivery = true
}

# =============================================================================
# IAM: extend hyperfleet-operator role with messaging permissions (per-MC)
#
# Follows the same incremental pattern as ${mc_name}-dynamodb-access: each MC
# pipeline run attaches its own named policy to the shared operator role.
# Parallel per-MC state files never collide because policy names are unique.
# =============================================================================

resource "aws_iam_role_policy" "hyperfleet_operator_messaging" {
  name = "${var.mc_name}-messaging-access"
  role = local.hyperfleet_operator_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SpecsTopicPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish",
        ]
        Resource = aws_sns_topic.specs.arn
      },
      {
        Sid    = "StatusQueuesReceive"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.status[*].arn
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
# SSM Parameter — specs topic ARN for operator configuration
# =============================================================================

resource "aws_ssm_parameter" "specs_topic_arn" {
  name        = "/${var.rc_id}/${var.mc_name}/messaging/specs-topic-arn"
  description = "SNS topic ARN for ${var.mc_name} specs change notifications (RC → MC)"
  type        = "String"
  value       = aws_sns_topic.specs.arn

  tags = merge(local.common_tags, {
    Name = "${var.rc_id}-${var.mc_name}-specs-topic-arn"
  })
}
