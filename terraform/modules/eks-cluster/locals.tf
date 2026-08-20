# =============================================================================
# Local Values
# =============================================================================

locals {
  cluster_id = var.cluster_id

  log_retention_days = 365

  common_tags = {
    function  = "cluster-infra"
    module    = "eks-cluster"
    ManagedBy = "terraform"
  }
}
