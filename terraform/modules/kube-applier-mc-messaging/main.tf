# =============================================================================
# kube-applier-mc-messaging Module
#
# Provisions the MC-side messaging resources for the specs path:
#   - An SQS queue in the MC account that receives specs change events
#     delivered cross-account from the RC-side SNS topic.
#   - A queue policy permitting the RC SNS topic to send messages.
#   - An inline IAM policy on the kube-applier role granting same-account
#     SQS receive on the queue.
#
# The RC-side SNS topic (provisioned by kube-applier-rc-messaging) subscribes
# to this queue and delivers messages via SNS push. This eliminates the
# previous cross-account SQS polling model (which required CMK) in favour of
# a push model that works with SSE-SQS (managed key), reducing cost and
# operational complexity.
#
# Resource naming:
#   Specs SQS queue (MC account): ${mc_name}-specs-notifications
#   RC-side SNS topic (RC account): ${mc_name}-specs-notifications
#
# Both names are deterministic — constructed from (mc_name, rc_account_id,
# region) so no cross-stack output passing is required.
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

  # RC-side specs SNS topic ARN — deterministic from known inputs.
  rc_specs_sns_topic_arn = "arn:${data.aws_partition.current.partition}:sns:${var.aws_region}:${var.rc_aws_account_id}:${var.mc_name}-specs-notifications"
}

# =============================================================================
# Specs SQS Queue — MC account receiver for RC → MC SNS cross-account delivery
#
# The RC-side SNS topic pushes spec change events here. kube-applier polls
# this same-account queue — no cross-account SQS or CMK required.
# SSE-SQS (managed key) is sufficient since SNS and the consumer are both
# scoped to the MC account.
# =============================================================================

resource "aws_sqs_queue" "specs" {
  name                       = "${var.mc_name}-specs-notifications"
  sqs_managed_sse_enabled    = true
  message_retention_seconds  = 300
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 20

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-specs-notifications"
    Direction = "specs-rc-to-mc"
  })
}

# Allow the RC-side SNS topic to deliver messages cross-account.
resource "aws_sqs_queue_policy" "specs" {
  queue_url = aws_sqs_queue.specs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowRCSNSSpecsDelivery"
      Effect = "Allow"
      Principal = {
        Service = "sns.amazonaws.com"
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.specs.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = local.rc_specs_sns_topic_arn
        }
      }
    }]
  })
}

# Cross-account SNS → SQS subscription. Placed here (MC module) rather than
# the RC module so that Terraform can express the dependency on both the queue
# and the queue policy. SNS cannot deliver the subscription confirmation
# message until the queue policy permits sqs:SendMessage from sns.amazonaws.com,
# so the subscription must be created after the policy exists.
#
# raw_message_delivery strips the SNS envelope so the SQS message body is
# identical to the pipe's input_template payload; no consumer code changes
# are required.
resource "aws_sns_topic_subscription" "specs" {
  topic_arn = local.rc_specs_sns_topic_arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.specs.arn

  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.specs]
}

# =============================================================================
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
    ]
  })
}
