# =============================================================================
# Outputs
# =============================================================================

output "service_id" {
  description = "PagerDuty service ID"
  value       = pagerduty_service.regional.id
}

output "service_name" {
  description = "PagerDuty service name"
  value       = pagerduty_service.regional.name
}

output "escalation_policy_id" {
  description = "PagerDuty escalation policy ID"
  value       = var.escalation_policy_id
}

output "integration_key_secret_name" {
  description = "AWS Secrets Manager secret name containing the PagerDuty integration key"
  value       = aws_secretsmanager_secret.pagerduty_integration_key.name
}

output "integration_key_secret_arn" {
  description = "AWS Secrets Manager secret ARN containing the PagerDuty integration key"
  value       = aws_secretsmanager_secret.pagerduty_integration_key.arn
}
