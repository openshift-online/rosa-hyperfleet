# =============================================================================
# kube-applier Module
#
# Creates IAM resources for the kube-applier-aws controller running on the
# Management Cluster. The controller reads ApplyDesire / DeleteDesire /
# ReadDesire documents from DynamoDB specs tables (read-only + streams) and
# writes status back to DynamoDB status tables (read-write).
#
# DynamoDB tables live in the RC account. Pod Identity provides cross-account
# IAM credentials to the controller pod.
# =============================================================================

data "aws_region" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Module    = "kube-applier"
    }
  )
}
