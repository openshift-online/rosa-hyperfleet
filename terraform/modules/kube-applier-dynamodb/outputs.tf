# =============================================================================
# kube-applier-dynamodb Module Outputs
# =============================================================================

output "specs_table_names" {
  description = "Names of the three DynamoDB specs tables for this MC"
  value       = { for k, v in aws_dynamodb_table.specs : k => v.name }
}

output "specs_table_arns" {
  description = "ARNs of the three DynamoDB specs tables for this MC"
  value       = { for k, v in aws_dynamodb_table.specs : k => v.arn }
}

output "specs_table_stream_arns" {
  description = "Stream ARNs of the three DynamoDB specs tables for this MC"
  value       = { for k, v in aws_dynamodb_table.specs : k => v.stream_arn }
}

output "status_table_names" {
  description = "Names of the three DynamoDB status tables for this MC"
  value       = { for k, v in aws_dynamodb_table.status : k => v.name }
}

output "status_table_arns" {
  description = "ARNs of the three DynamoDB status tables for this MC"
  value       = { for k, v in aws_dynamodb_table.status : k => v.arn }
}

output "backend_role_arn" {
  description = "IAM role ARN for the kube-applier backend service (reads/writes desires across all MCs)"
  value       = aws_iam_role.kube_applier_backend.arn
}
