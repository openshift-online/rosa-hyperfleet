resource "aws_acm_certificate" "grafana" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = {
    Name = "${var.regional_id}-grafana-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  zone_id         = var.regional_hosted_zone_id
  name            = tolist(aws_acm_certificate.grafana.domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.grafana.domain_validation_options)[0].resource_record_type
  ttl             = 300
  records         = [tolist(aws_acm_certificate.grafana.domain_validation_options)[0].resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "grafana" {
  certificate_arn         = aws_acm_certificate.grafana.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
}
