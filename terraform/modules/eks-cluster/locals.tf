# =============================================================================
# Local Values
# =============================================================================

locals {
  cluster_id = var.cluster_id

  # Availability zone selection
  # Use provided AZs if given, otherwise auto-detect the first 3 available AZs
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  log_retention_days = 365 # 365 days for all regions (AU-11)
}