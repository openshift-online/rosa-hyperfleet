# =============================================================================
# kube-applier-rc-messaging Module Outputs
# =============================================================================

output "specs_pipe_applydesires_arn" {
  description = "ARN of the EventBridge Pipe delivering specs-applydesires changes to the MC SQS queue"
  value       = aws_pipes_pipe.specs_applydesires.arn
}

output "specs_pipe_readdesires_arn" {
  description = "ARN of the EventBridge Pipe delivering specs-readdesires changes to the MC SQS queue"
  value       = aws_pipes_pipe.specs_readdesires.arn
}

output "status_pipe_role_arn" {
  description = "ARN of the IAM role used by the status EventBridge Pipes"
  value       = aws_iam_role.status_pipe.arn
}

output "specs_pipe_role_arn" {
  description = "ARN of the IAM role used by the specs EventBridge Pipes"
  value       = aws_iam_role.specs_pipe.arn
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
