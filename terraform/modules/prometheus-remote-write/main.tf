# =============================================================================
# Prometheus Remote Write Module
#
# Creates an IAM role for Prometheus on the Management Cluster to send
# metrics to Thanos Receive on the Regional Cluster via API Gateway.
# Uses EKS Pod Identity for credential injection.
# =============================================================================

data "aws_region" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      function          = "observability"
      module            = "prometheus-remote-write"
      Component         = "prometheus-remote-write"
      ManagementCluster = var.management_id
      ManagedBy         = "terraform"
    }
  )
}
