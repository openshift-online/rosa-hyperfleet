# =============================================================================
# CloudWatch Exporter Module - Main Configuration
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      Component = "cloudwatch-exporter"
      ManagedBy = "terraform"
    
    function  = "observability"
    module    = "cloudwatch-exporter"}
  )
}
