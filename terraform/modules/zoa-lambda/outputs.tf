# =============================================================================
# ZOA per-VPC Lambda Module Outputs
# =============================================================================

output "api_function_name" {
  description = "Name of the API Lambda function"
  value       = aws_lambda_function.api.function_name
}

output "api_function_arn" {
  description = "ARN of the API Lambda function"
  value       = aws_lambda_function.api.arn
}

output "api_function_url" {
  description = "Function URL for the API Lambda (used by rosa-boundary CLI)"
  value       = aws_lambda_function_url.api.function_url
}

output "worker_function_name" {
  description = "Name of the Worker Lambda function"
  value       = aws_lambda_function.worker.function_name
}

output "worker_function_arn" {
  description = "ARN of the Worker Lambda function (used for self-invocation)"
  value       = aws_lambda_function.worker.arn
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution IAM role (shared by api + worker)"
  value       = aws_iam_role.lambda.arn
}

output "lambda_role_name" {
  description = "Name of the Lambda execution IAM role"
  value       = aws_iam_role.lambda.name
}

output "dlq_arn" {
  description = "ARN of the SQS Dead Letter Queue"
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "URL of the SQS Dead Letter Queue"
  value       = aws_sqs_queue.dlq.url
}
