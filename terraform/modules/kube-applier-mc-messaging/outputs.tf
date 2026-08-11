# =============================================================================
# kube-applier-mc-messaging Module Outputs
# =============================================================================

output "specs_queue_arn" {
  description = "ARN of the MC-side specs SQS queue that receives cross-account delivery from the RC SNS topic"
  value       = aws_sqs_queue.specs.arn
}

output "specs_queue_url" {
  description = "URL of the MC-side specs SQS queue polled by kube-applier"
  value       = aws_sqs_queue.specs.url
}
