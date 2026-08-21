# =============================================================================
# ROSA Authorization Module - Main Configuration
#
# This module creates AWS resources for ROSA Cedar/AVP-based authorization:
# - DynamoDB tables for accounts, admins, groups, policies, attachments
# - IAM roles for Pod Identity access to DynamoDB and AVP
# =============================================================================

# =============================================================================
# Data Sources
# =============================================================================

data "aws_region" "current" {}

# tflint-ignore: terraform_unused_declarations
data "aws_caller_identity" "current" {}

# =============================================================================
# Local Variables
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      Module    = "authz"
      ManagedBy = "terraform"

      function = "authz"
    module = "authz" }
  )

  # Table names following the pattern: ${regional_id}-authz-${purpose}
  table_names = {
    accounts    = "${var.regional_id}-authz-accounts"
    admins      = "${var.regional_id}-authz-admins"
    groups      = "${var.regional_id}-authz-groups"
    members     = "${var.regional_id}-authz-group-members"
    policies    = "${var.regional_id}-authz-policies"
    attachments = "${var.regional_id}-authz-attachments"
  }
}
