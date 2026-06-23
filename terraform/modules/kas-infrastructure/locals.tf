# =============================================================================
# KAS Infrastructure Module - Local Variables
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Module    = "kas-infrastructure"
    }
  )
}
