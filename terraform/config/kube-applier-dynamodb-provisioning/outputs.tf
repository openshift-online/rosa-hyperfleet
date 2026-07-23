output "specs_table_arns" {
  description = "ARNs of the specs DynamoDB tables"
  value       = module.kube_applier_dynamodb.specs_table_arns
}

output "status_table_arns" {
  description = "ARNs of the status DynamoDB tables"
  value       = module.kube_applier_dynamodb.status_table_arns
}

output "status_readdesires_stream_arn" {
  description = "Stream ARN for the status-readdesires table"
  value       = module.kube_applier_dynamodb.status_readdesires_stream_arn
}

# =============================================================================
# Messaging Outputs
# Read by the MC management-cluster buildspec to pass rc_specs_sns_topic_arn
# into the MC terraform run.
# =============================================================================

output "specs_sns_topic_arn" {
  description = "ARN of the RC-account specs SNS topic for this MC (operator publishes here after writing a desire document). Empty when messaging is not yet provisioned."
  value       = length(module.kube_applier_rc_messaging) > 0 ? module.kube_applier_rc_messaging[0].specs_topic_arn : ""
}

output "status_sqs_queue_urls" {
  description = "URLs of the RC-account operator status SQS queues (one per replica). Empty list when messaging is not yet provisioned."
  value       = length(module.kube_applier_rc_messaging) > 0 ? module.kube_applier_rc_messaging[0].status_queue_urls : []
}

