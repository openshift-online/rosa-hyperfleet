# =============================================================================
# Bedrock account primitives (per AWS account + Region)
# =============================================================================
# Not coupled to ZOA or any workload module. Call from regional/management cluster
# stacks today; later move to dedicated per-account Terraform with the same module.
#
# Shared ephemeral/CI pool accounts: skip create when AWS already has the object
# (data.external probes). Skipped resources are NOT imported into cluster state —
# janitor destroy of one ephemeral stack does not remove account-wide agreements,
# budget that other stacks rely on.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  common_tags = merge(var.tags, {
    Component = "bedrock"
    ManagedBy = "terraform"
    module    = "bedrock"
  })

  account_primitive_check_program = [
    "${path.module}/scripts/check_account_primitive.sh",
  ]

  budget_subscriber_email = replace(
    var.budget_notification_email,
    "@",
    "+${data.aws_caller_identity.current.account_id}@",
  )
}
