# =============================================================================
# Local Values
# =============================================================================

locals {
  cluster_id = var.cluster_id

  # Availability zone selection
  # Use provided AZs if given, otherwise auto-detect the first 3 available AZs
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  # FedRAMP AU-11 requires 365-day retention; only US regions are FedRAMP-scoped
  log_retention_days = startswith(data.aws_region.current.id, "us-") ? 365 : 30
}