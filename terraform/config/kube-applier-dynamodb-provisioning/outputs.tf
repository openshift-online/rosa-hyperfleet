# =============================================================================
# kube-applier DynamoDB Provisioning - Outputs
# =============================================================================

output "specs_table_names" {
  description = "Names of the three DynamoDB specs tables for this MC"
  value       = module.kube_applier_dynamodb.specs_table_names
}

output "specs_table_arns" {
  description = "ARNs of the three DynamoDB specs tables for this MC"
  value       = module.kube_applier_dynamodb.specs_table_arns
}

output "specs_table_stream_arns" {
  description = "Stream ARNs of the three DynamoDB specs tables for this MC"
  value       = module.kube_applier_dynamodb.specs_table_stream_arns
}

output "status_table_names" {
  description = "Names of the three DynamoDB status tables for this MC"
  value       = module.kube_applier_dynamodb.status_table_names
}

output "status_table_arns" {
  description = "ARNs of the three DynamoDB status tables for this MC"
  value       = module.kube_applier_dynamodb.status_table_arns
}

output "backend_role_arn" {
  description = "IAM role ARN for the kube-applier backend service"
  value       = module.kube_applier_dynamodb.backend_role_arn
}
