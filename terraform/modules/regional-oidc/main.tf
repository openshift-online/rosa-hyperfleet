# =============================================================================
# Regional OIDC Module
#
# Creates the shared OIDC infrastructure owned by the Regional Cluster:
# - KMS key for S3 encryption
# - Private S3 bucket for OIDC discovery documents (one per region)
# - CloudFront distribution for the public OIDC endpoint
#
# Management Clusters write to this bucket cross-account via a bucket policy.
# The CloudFront domain becomes the stable OIDC issuer base URL — it does not
# change when hosted clusters migrate between Management Clusters.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  bucket_name = "hypershift-${var.regional_id}-oidc-${data.aws_caller_identity.current.account_id}"
}