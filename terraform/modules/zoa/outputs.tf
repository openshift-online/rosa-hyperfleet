output "table_name" {
  description = "DynamoDB table name for ZOA executions"
  value       = aws_dynamodb_table.executions.name
}

output "audit_table_name" {
  description = "DynamoDB table name for ZOA audit log"
  value       = aws_dynamodb_table.audit_log.name
}

output "bucket_name" {
  description = "S3 bucket name for ZOA outputs"
  value       = aws_s3_bucket.outputs.id
}

output "bucket_arn" {
  description = "S3 bucket ARN for ZOA outputs"
  value       = aws_s3_bucket.outputs.arn
}

output "kms_key_arn" {
  description = "KMS key ARN for ZOA encryption"
  value       = aws_kms_key.zoa.arn
}

# Lambda outputs

output "table_arn" {
  description = "DynamoDB executions table ARN (for cross-account policies)"
  value       = aws_dynamodb_table.executions.arn
}

output "audit_table_arn" {
  description = "DynamoDB audit log table ARN (for cross-account policies)"
  value       = aws_dynamodb_table.audit_log.arn
}

output "uploader_role_arn" {
  description = "ARN of the uploader IAM role (Lambda assumes this for scoped S3 creds)"
  value       = aws_iam_role.uploader.arn
}

output "data_access_role_arn" {
  description = "ARN of the data-access role (MC Lambdas assume this for cross-account DynamoDB+S3)"
  value       = aws_iam_role.data_access.arn
}

# ECR

output "lambda_ecr_url" {
  description = "ECR repository URL for zoa-lambda image (normalized to non-FIPS endpoint)"
  value       = replace(aws_ecr_repository.lambda.repository_url, "ecr-fips", "ecr")
}

output "lambda_image_uri" {
  description = "Full ECR image URI for Lambda (repo:tag). Normalized to non-FIPS endpoint for Lambda API compatibility."
  value       = var.zoa_image_tag != "" ? "${replace(aws_ecr_repository.lambda.repository_url, "ecr-fips", "ecr")}:${var.zoa_image_tag}" : ""
}

output "runner_image_uri" {
  description = "Source image URI for the K8s Job runner. K8s nodes pull directly from source registry."
  value       = var.zoa_image_tag != "" ? "${var.zoa_runner_source_image}:${var.zoa_image_tag}" : ""
}

