# =============================================================================
# Custom Domain (Optional)
#
# When api_domain_name is set, creates:
# - ACM certificate with DNS validation
# - Route53 validation records
# - API Gateway custom domain name (REGIONAL)
# - Base path mapping to the prod stage
#
# Note: all resources are gated on api_domain_name only (not regional_hosted_zone_id)
# because regional_hosted_zone_id is derived from a resource created in the same
# apply and is unknown at plan time.
# =============================================================================

# -----------------------------------------------------------------------------
# ACM Certificate
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "api" {
  count = var.api_domain_name != null ? 1 : 0

  domain_name       = var.api_domain_name
  validation_method = "DNS"

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api-cert"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Route53 DNS Validation Records
# -----------------------------------------------------------------------------

resource "aws_route53_record" "cert_validation" {
  count = var.api_domain_name != null ? 1 : 0

  zone_id         = var.regional_hosted_zone_id
  name            = tolist(aws_acm_certificate.api[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.api[0].domain_validation_options)[0].resource_record_type
  ttl             = 300
  records         = [tolist(aws_acm_certificate.api[0].domain_validation_options)[0].resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "api" {
  count = var.api_domain_name != null ? 1 : 0

  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [aws_route53_record.cert_validation[0].fqdn]
}

# -----------------------------------------------------------------------------
# API Gateway Custom Domain Name
# -----------------------------------------------------------------------------

resource "aws_api_gateway_domain_name" "api" {
  count = var.api_domain_name != null ? 1 : 0

  domain_name              = var.api_domain_name
  regional_certificate_arn = aws_acm_certificate_validation.api[0].certificate_arn

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api-domain"
  })
}

# -----------------------------------------------------------------------------
# Base Path Mapping
# -----------------------------------------------------------------------------

resource "aws_api_gateway_base_path_mapping" "api" {
  count = var.api_domain_name != null ? 1 : 0

  api_id      = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  domain_name = aws_api_gateway_domain_name.api[0].domain_name
}

# -----------------------------------------------------------------------------
# Route53 Alias Record
#
# Points the custom domain to the API Gateway regional domain name.
# -----------------------------------------------------------------------------

resource "aws_route53_record" "api" {
  count = var.api_domain_name != null ? 1 : 0

  zone_id = var.regional_hosted_zone_id
  name    = var.api_domain_name
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.api[0].regional_domain_name
    zone_id                = aws_api_gateway_domain_name.api[0].regional_zone_id
    evaluate_target_health = true
  }
}
