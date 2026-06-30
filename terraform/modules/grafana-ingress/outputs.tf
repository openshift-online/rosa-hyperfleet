output "target_group_arn" {
  description = "Target group ARN for TargetGroupBinding in Kubernetes"
  value       = aws_lb_target_group.grafana.arn
}

output "grafana_domain" {
  description = "Grafana FQDN (e.g. grafana.us-east-1.int0.rosa.devshift.net)"
  value       = var.domain_name
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.grafana.dns_name
}
