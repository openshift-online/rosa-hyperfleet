# =============================================================================
# kube-applier-rc-messaging Module Outputs
# =============================================================================

output "specs_topic_arn" {
  description = "ARN of the specs SNS topic in the RC account that the hyperfleet-operator publishes to"
  value       = aws_sns_topic.specs.arn
}

output "specs_topic_name" {
  description = "Name of the specs SNS topic"
  value       = aws_sns_topic.specs.name
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
