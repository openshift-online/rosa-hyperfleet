# =============================================================================
# CloudWatch Exporter Module - Main Configuration
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      Component              = "cloudwatch-exporter"
      ManagedBy              = "terraform"
      managed-by-integration = "https://github.com/openshift-online/rosa-regional-platform/terraform/modules/cloudwatch-exporter"
    }
  )
}
