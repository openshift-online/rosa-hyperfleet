# =============================================================================
# Pipeline Provisioner Outputs
# =============================================================================

output "provisioner_pipeline_name" {
  description = "Name of the Pipeline Provisioner CodePipeline"
  value       = aws_codepipeline.provisioner.name
}

output "provisioner_pipeline_arn" {
  description = "ARN of the Pipeline Provisioner CodePipeline"
  value       = aws_codepipeline.provisioner.arn
}

output "github_connection_arn" {
  description = "ARN of the shared GitHub connection"
  value       = data.aws_codestarconnections_connection.github.arn
}

output "github_connection_status" {
  description = "Status of the shared GitHub connection (requires manual authorization)"
  value       = data.aws_codestarconnections_connection.github.connection_status
}

output "provisioner_role_arn" {
  description = "ARN of the IAM role used by the provisioner CodeBuild project"
  value       = aws_iam_role.codebuild_role.arn
}

# =============================================================================
# General Information
# =============================================================================

output "central_account_id" {
  description = "AWS Account ID where pipeline provisioner is deployed"
  value       = data.aws_caller_identity.current.account_id
}

output "deployment_region" {
  description = "AWS Region where pipeline provisioner is deployed"
  value       = data.aws_region.current.id
}

