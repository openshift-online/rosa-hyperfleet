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

output "specs_table_stream_arns" {
  description = "Stream ARNs of the two DynamoDB specs tables for this MC"
  value       = { for k, v in aws_dynamodb_table.specs : k => v.stream_arn }
}

output "status_table_names" {
  description = "Names of the two DynamoDB status tables for this MC"
  value       = { for k, v in aws_dynamodb_table.status : k => v.name }
}

output "status_table_arns" {
  description = "ARNs of the two DynamoDB status tables for this MC"
  value       = { for k, v in aws_dynamodb_table.status : k => v.arn }
}

output "specs_applydesires_stream_arn" {
  description = "Stream ARN for the specs-applydesires table (source for EventBridge Pipe → MC SQS)"
  value       = aws_dynamodb_table.specs["${var.mc_name}-specs-applydesires"].stream_arn
}

output "specs_readdesires_stream_arn" {
  description = "Stream ARN for the specs-readdesires table (source for EventBridge Pipe → MC SQS)"
  value       = aws_dynamodb_table.specs["${var.mc_name}-specs-readdesires"].stream_arn
}

output "status_applydesires_stream_arn" {
  description = "Stream ARN for the status-applydesires table (source for EventBridge Pipe → RC SQS)"
  value       = aws_dynamodb_table.status["${var.mc_name}-status-applydesires"].stream_arn
}

output "status_readdesires_stream_arn" {
  description = "Stream ARN for the status-readdesires table (source for EventBridge Pipe → RC SQS)"
  value       = aws_dynamodb_table.status["${var.mc_name}-status-readdesires"].stream_arn
}
