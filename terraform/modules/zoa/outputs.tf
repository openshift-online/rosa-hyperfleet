output "table_name" {
  description = "DynamoDB table name for ZOA executions"
  value       = aws_dynamodb_table.executions.name
}

output "bucket_name" {
  description = "S3 bucket name for ZOA outputs"
  value       = aws_s3_bucket.outputs.id
}

output "job_role_arn" {
  description = "IAM role ARN for ZOA jobs on MCs"
  value       = aws_iam_role.job.arn
}

output "kms_key_arn" {
  description = "KMS key ARN for ZOA encryption"
  value       = aws_kms_key.zoa.arn
}
