output "github_connection_arn" {
  description = "ARN of the GitHub CodeStar connection"
  value       = data.aws_codestarconnections_connection.github.arn
}

output "pipeline_name" {
  description = "Name of the CodePipeline"
  value       = aws_codepipeline.central_pipeline.name
}

output "pipeline_arn" {
  description = "ARN of the CodePipeline"
  value       = aws_codepipeline.central_pipeline.arn
}

output "codebuild_validate_name" {
  description = "Name of the validation CodeBuild project"
  value       = aws_codebuild_project.regional_validate.name
}

output "codebuild_apply_name" {
  description = "Name of the apply CodeBuild project"
  value       = aws_codebuild_project.regional_apply.name
}

output "codebuild_bootstrap_name" {
  description = "Name of the bootstrap CodeBuild project"
  value       = aws_codebuild_project.regional_bootstrap.name
}

output "artifact_bucket" {
  description = "S3 bucket used for pipeline artifacts"
  value       = aws_s3_bucket.pipeline_artifact.id
}
