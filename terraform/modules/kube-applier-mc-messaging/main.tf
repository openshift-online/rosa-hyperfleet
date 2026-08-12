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
# The RC-side SNS topic (provisioned by kube-applier-rc-messaging) delivers
# messages to this queue via SNS push. The cross-account SNS→SQS subscription
# is NOT managed in Terraform — it is wired imperatively in register.sh by
# calling `aws sns subscribe` as the MC account (the queue owner), which is
# required for AWS to auto-confirm the subscription. Terraform's
# aws_sns_topic_subscription always calls SNS APIs in the topic's account
# (RC), which cannot auto-confirm a subscription to an MC-side queue.
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

# =============================================================================
# IAM: extend kube-applier role with same-account SQS receive permissions
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
