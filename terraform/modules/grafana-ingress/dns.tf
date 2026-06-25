resource "aws_route53_record" "grafana" {
  zone_id = var.regional_hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.grafana.dns_name
    zone_id                = aws_lb.grafana.zone_id
    evaluate_target_health = true
  }
}
