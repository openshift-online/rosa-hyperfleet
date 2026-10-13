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
  description = "Function URL for the API Lambda (used by ZOA boundary tasks and CLI)"
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

# --- ZOA Access execution role (RC creates; MC uses var.access_lambda_role_arn) ---

output "access_lambda_role_arn" {
  description = "ARN of the ZOA Access Lambda execution role (RC output for MC boundary trust)"
  value       = local.access_lambda_role_arn
}

output "access_lambda_role_name" {
  description = "Name of the ZOA Access Lambda execution role"
  value       = var.target_type == "rc" ? aws_iam_role.access_lambda[0].name : element(split("/", local.access_lambda_role_arn), length(split("/", local.access_lambda_role_arn)) - 1)
}

# --- Boundary (ECS) ---

output "boundary_ecs_cluster_name" {
  description = "Name of the ECS cluster for ZOA Boundary tasks"
  value       = aws_ecs_cluster.boundary.name
}

output "boundary_ecs_cluster_arn" {
  description = "ARN of the ECS cluster for ZOA Boundary tasks"
  value       = aws_ecs_cluster.boundary.arn
}

output "boundary_task_definition_arn" {
  description = "ARN of the ZOA Boundary task definition"
  value       = aws_ecs_task_definition.boundary.arn
}

output "boundary_task_definition_arn_prefix" {
  description = "ARN of the ZOA Boundary task definition family (for IAM Resource scoping)"
  value       = aws_ecs_task_definition.boundary.arn_without_revision
}

output "boundary_security_group_id" {
  description = "Security group ID for ZOA Boundary tasks"
  value       = aws_security_group.boundary.id
}

output "boundary_exec_scoped_role_arn" {
  description = "IAM role ARN vended on session join for per-task ECS Exec"
  value       = aws_iam_role.exec_scoped.arn
}

output "boundary_ecs_exec_interactive_command" {
  description = "Interactive shell command for ecs:ExecuteCommand (Access Lambda env + task ZOA_ECS_EXEC_COMMAND)"
  value       = var.boundary_ecs_exec_interactive_command
}
