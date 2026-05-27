# =============================================================================
# HyperShift OIDC Module
#
# Creates the MC-side OIDC infrastructure:
# - IAM role and Pod Identity for the HyperShift operator (writes to regional S3)
# - IAM role and Pod Identity for the HyperShift installer Job
# - Secrets Manager secret with OIDC configuration
#
# S3 and CloudFront are owned by the Regional Cluster (regional-oidc module).
# The bucket ARN, name, region, and CloudFront domain are passed in as variables.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      Component         = "hypershift-oidc"
      ManagementCluster = var.cluster_id
      ManagedBy         = "terraform"
    }
  )
}