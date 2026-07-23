# =============================================================================
# kube-applier-mc-messaging Module Outputs
# =============================================================================

output "specs_queue_arn" {
  description = "ARN of the specs SQS queue that receives notifications from the RC EventBridge Pipe"
  value       = aws_sqs_queue.specs.arn
}

output "specs_queue_url" {
  description = "URL of the specs SQS queue for use by kube-applier"
  value       = aws_sqs_queue.specs.url
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt MC-side messaging resources"
  value       = aws_kms_key.messaging.arn
}
