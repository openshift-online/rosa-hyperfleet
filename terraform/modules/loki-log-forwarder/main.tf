# =============================================================================
# Loki Log Forwarder Module
#
# Creates an IAM role for the sigv4-proxy on the Management Cluster to send
# logs to Loki Distributor on the Regional Cluster via API Gateway.
# Uses EKS Pod Identity for credential injection.
#
# Mirrors the prometheus-remote-write module pattern.
# =============================================================================

data "aws_region" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      function          = "observability"
      module            = "loki-log-forwarder"
      Component         = "loki-log-forwarder"
      ManagementCluster = var.management_id
      ManagedBy         = "terraform"
    }
  )
}
