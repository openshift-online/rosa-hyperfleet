output "container_image" {
  description = "Full container image reference (repository:tag)"
  value       = local.container_image
}

output "ecr_repository_url" {
  description = "Public ECR repository URL"
  value       = aws_ecrpublic_repository.platform.repository_uri
}

output "image_tag" {
  description = "Current image tag derived from Dockerfile, provider versions, and generator script SHA"
  value       = local.combined_hash
}
