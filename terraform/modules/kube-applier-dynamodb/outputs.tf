# =============================================================================
# kube-applier-dynamodb Module Outputs
# =============================================================================

output "specs_table_names" {
  description = "Names of the two DynamoDB specs tables for this MC"
  value       = { for k, v in aws_dynamodb_table.specs : k => v.name }
}

output "specs_table_arns" {
  description = "ARNs of the two DynamoDB specs tables for this MC"
  value       = { for k, v in aws_dynamodb_table.specs : k => v.arn }
}

output "status_table_names" {
  description = "Names of the two DynamoDB status tables for this MC"
  value       = { for k, v in aws_dynamodb_table.status : k => v.name }
}

output "status_table_arns" {
  description = "ARNs of the two DynamoDB status tables for this MC"
  value       = { for k, v in aws_dynamodb_table.status : k => v.arn }
}

