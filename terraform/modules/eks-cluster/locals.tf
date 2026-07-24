# =============================================================================
# Local Values
# =============================================================================

locals {
  cluster_id = var.cluster_id

  log_retention_days = 365

  # OIDC issuer URL without https:// prefix — used as the condition key in IRSA trust policies.
  oidc_issuer = trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")
}
