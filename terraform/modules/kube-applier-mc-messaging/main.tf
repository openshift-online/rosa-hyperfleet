# =============================================================================
# kube-applier-mc-messaging Module
#
# Provisions the MC-side IAM permissions for kube-applier to poll its
# specs SQS queue, which now lives in the RC account.
#
# All SQS queues and KMS keys are provisioned in the RC account by the
# kube-applier-rc-messaging module. This module extends the MC-account
# kube-applier IAM role with the cross-account SQS receive and KMS decrypt
# permissions needed to drain the RC-side specs queue.
#
# Resource naming:
#   Specs SQS queue (RC account): ${mc_name}-specs-notifications
#   KMS key (RC account):         alias/${mc_name}-kube-applier-messaging
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

  # RC-side specs SQS queue ARN — deterministic from known inputs.
  rc_specs_queue_arn = "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${var.rc_aws_account_id}:${var.mc_name}-specs-notifications"

  # RC-side KMS key ARN pattern for the identity-based policy.
  # Alias ARNs cannot be used as Resource in identity-based policies for kms:Decrypt;
  # only key ARNs are valid. Since we don't have the key ID without cross-stack output
  # passing, we scope to all keys in the RC account/region — the KMS key resource policy
  # is the actual access gate (it only allows this role via aws:PrincipalArn condition).
  rc_kms_key_arn_pattern = "arn:${data.aws_partition.current.partition}:kms:${var.aws_region}:${var.rc_aws_account_id}:key/*"
}

# =============================================================================
# IAM: extend kube-applier role with cross-account RC SQS permissions
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
        Resource = local.rc_specs_queue_arn
      },
      {
        Sid    = "SpecsQueueKMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = local.rc_kms_key_arn_pattern
      },
    ]
  })
}
