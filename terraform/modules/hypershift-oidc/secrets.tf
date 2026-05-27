# =============================================================================
# Secrets Manager - HyperShift Configuration
#
# Stores OIDC configuration that the install Job reads via ASCP CSI driver.
# This eliminates hardcoded values in ArgoCD config — the bucket name and
# region are derived from Terraform and consumed at runtime.
# =============================================================================

resource "aws_secretsmanager_secret" "hypershift_config" {
  name        = "hypershift/${var.cluster_id}-config"
  description = "HyperShift OIDC configuration for the install Job"

  tags = merge(
    local.common_tags,
    {
      Name = "hypershift-config"
    }
  )
}

resource "aws_secretsmanager_secret_version" "hypershift_config" {
  secret_id = aws_secretsmanager_secret.hypershift_config.id

  secret_string = jsonencode({
    oidcBucketName   = var.oidc_bucket_name
    oidcBucketRegion = var.oidc_bucket_region
    oidcIssuerUrl    = "https://${var.oidc_cloudfront_domain}"
  })
}