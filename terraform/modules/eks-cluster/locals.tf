# =============================================================================
# Local Values
# =============================================================================

locals {
  cluster_id = var.cluster_id

  log_retention_days = 365

  # OIDC issuer URL without https:// prefix — used as the condition key in IRSA trust policies.
  # Empty string when Karpenter is disabled to avoid a forward reference on the cluster resource.
  oidc_issuer = var.enable_karpenter ? trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://") : ""
}
