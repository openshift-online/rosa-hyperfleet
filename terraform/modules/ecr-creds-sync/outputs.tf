output "ecr_creds_sync_role_arn" {
  description = "IAM role ARN for the ecr-creds-sync controller"
  value       = aws_iam_role.ecr_creds_sync.arn
}
