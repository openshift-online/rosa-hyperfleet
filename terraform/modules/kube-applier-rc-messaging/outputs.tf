# =============================================================================
# kube-applier-rc-messaging Module Outputs
# =============================================================================

output "specs_pipe_applydesires_arn" {
  description = "ARN of the EventBridge Pipe delivering specs-applydesires changes to the RC specs SNS topic"
  value       = aws_pipes_pipe.specs_applydesires.arn
}

output "specs_pipe_readdesires_arn" {
  description = "ARN of the EventBridge Pipe delivering specs-readdesires changes to the RC specs SNS topic"
  value       = aws_pipes_pipe.specs_readdesires.arn
}

output "specs_sns_topic_arn" {
  description = "ARN of the RC-side specs SNS topic that delivers cross-account to the MC-side SQS queue"
  value       = aws_sns_topic.specs.arn
}

output "status_pipe_applydesires_arn" {
  description = "ARN of the EventBridge Pipe delivering status-applydesires changes to the SNS fan-out topic"
  value       = aws_pipes_pipe.status_applydesires.arn
}

output "status_pipe_readdesires_arn" {
  description = "ARN of the EventBridge Pipe delivering status-readdesires changes to the SNS fan-out topic"
  value       = aws_pipes_pipe.status_readdesires.arn
}

output "status_sns_applydesires_topic_arn" {
  description = "ARN of the SNS topic that fans out status-applydesires events to all operator replica SQS queues"
  value       = aws_sns_topic.status_applydesires.arn
}

output "status_sns_readdesires_topic_arn" {
  description = "ARN of the SNS topic that fans out status-readdesires events to all operator replica SQS queues"
  value       = aws_sns_topic.status_readdesires.arn
}

output "status_queue_arns" {
  description = "ARNs of the RC-side status SQS queues (one per operator replica, indexed 0..N-1)"
  value       = aws_sqs_queue.status[*].arn
}

output "status_queue_urls" {
  description = "URLs of the RC-side status SQS queues (one per operator replica, indexed 0..N-1)"
  value       = aws_sqs_queue.status[*].url
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt RC-side messaging resources for this MC"
  value       = aws_kms_key.messaging.arn
}
