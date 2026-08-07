output "specs_table_arns" {
  description = "ARNs of the specs DynamoDB tables"
  value       = module.kube_applier_dynamodb.specs_table_arns
}

output "status_table_arns" {
  description = "ARNs of the status DynamoDB tables"
  value       = module.kube_applier_dynamodb.status_table_arns
}

# =============================================================================
# DynamoDB Stream ARN Outputs
# Consumed by the kube-applier-rc-messaging module to configure EventBridge
# Pipes that deliver change notifications directly to SQS queues.
# =============================================================================

output "specs_applydesires_stream_arn" {
  description = "Stream ARN for the specs-applydesires table (EventBridge Pipe source)"
  value       = module.kube_applier_dynamodb.specs_applydesires_stream_arn
}

output "specs_readdesires_stream_arn" {
  description = "Stream ARN for the specs-readdesires table (EventBridge Pipe source)"
  value       = module.kube_applier_dynamodb.specs_readdesires_stream_arn
}

output "status_applydesires_stream_arn" {
  description = "Stream ARN for the status-applydesires table (EventBridge Pipe source)"
  value       = module.kube_applier_dynamodb.status_applydesires_stream_arn
}

output "status_readdesires_stream_arn" {
  description = "Stream ARN for the status-readdesires table (EventBridge Pipe source)"
  value       = module.kube_applier_dynamodb.status_readdesires_stream_arn
}

output "status_sqs_queue_urls" {
  description = "URLs of the RC-account operator status SQS queues (one per replica)."
  value       = module.kube_applier_rc_messaging.status_queue_urls
}

output "specs_sqs_queue_url" {
  description = "URL of the RC-account specs SQS queue polled by kube-applier cross-account."
  value       = module.kube_applier_rc_messaging.specs_queue_url
}
