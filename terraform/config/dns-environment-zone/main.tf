# =============================================================================
# DNS Environment Zone
#
# Creates a Route53 hosted zone for the environment domain
# (e.g. int0.rosa.devshift.net) in the central account.
#
# Outputs NS records for upstream delegation (manual or automated).
# =============================================================================

resource "aws_route53_zone" "environment" {
  name = var.environment_domain

  tags = {
    Name        = var.environment_domain
    Environment = var.environment
    function    = "dns"
    module      = "dns-environment-zone"
    ManagedBy   = "terraform"
  }
}
