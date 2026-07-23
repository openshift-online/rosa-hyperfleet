# =============================================================================
# DNS and TLS (optional)
#
# All resources are gated on environment_domain being set. When not set (e.g.
# ephemeral environments without a custom domain), no ACM cert or Route53
# records are created and the ALB falls back to an HTTP listener.
#
# When enabled, creates:
# - ACM wildcard certificate: *.sre.{deployment_name}.{environment_domain}
# - Route53 DNS validation record
# - Route53 A-record aliases for each service hostname
# =============================================================================

locals {
  sre_domain = local.has_domain ? "sre.${var.deployment_name}.${var.environment_domain}" : null
}

# -----------------------------------------------------------------------------
# ACM Wildcard Certificate
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "sre" {
  count = local.has_domain ? 1 : 0

  domain_name       = "*.${local.sre_domain}"
  validation_method = "DNS"

  tags = {
    Name = "${var.regional_id}-sre-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Route53 DNS Validation Record
# -----------------------------------------------------------------------------

resource "aws_route53_record" "cert_validation" {
  count = local.has_domain ? 1 : 0

  zone_id         = var.regional_hosted_zone_id
  name            = tolist(aws_acm_certificate.sre[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.sre[0].domain_validation_options)[0].resource_record_type
  ttl             = 300
  records         = [tolist(aws_acm_certificate.sre[0].domain_validation_options)[0].resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "sre" {
  count = local.has_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.sre[0].arn
  validation_record_fqdns = [aws_route53_record.cert_validation[0].fqdn]
}

# -----------------------------------------------------------------------------
# Route53 Alias Records — one per service
# -----------------------------------------------------------------------------

locals {
  sre_services = local.has_domain ? keys(local.services) : []
}

resource "aws_route53_record" "sre" {
  for_each = toset(local.sre_services)

  zone_id = var.regional_hosted_zone_id
  name    = "${each.key}.${local.sre_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.sre.dns_name
    zone_id                = aws_lb.sre.zone_id
    evaluate_target_health = true
  }
}
