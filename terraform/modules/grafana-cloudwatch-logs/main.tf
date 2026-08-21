# =============================================================================
# Grafana CloudWatch Logs Module - Main Configuration
#
# Provides IAM roles for Grafana to query CloudWatch Logs.
#
# Modes:
#   primary — Deployed on Regional Cluster. Creates IAM role with Pod Identity
#             and permission to read logs + assume reader roles in MC accounts.
#   reader  — Deployed on Management Cluster. Creates a role that trusts the
#             RC Grafana role, granting CW Logs read access in the MC account.
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      function  = "observability"
      module    = "grafana-cloudwatch-logs"
      Component = "grafana-cloudwatch-logs"
      ManagedBy = "terraform"
    }
  )
}
