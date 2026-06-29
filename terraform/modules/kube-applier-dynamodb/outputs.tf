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

output "status_readdesires_stream_arn" {
  description = "Stream ARN for the status-readdesires table (used by hyperfleet-operator for event-driven manifest status)"
  value       = aws_dynamodb_table.status["${var.mc_name}-status-readdesires"].stream_arn
}
