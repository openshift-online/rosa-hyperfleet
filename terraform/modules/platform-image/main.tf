# Platform Image Module
# Manages the shared public ECR repository and image tag for the platform container image.
# This image is used by both the bastion and ecs-bootstrap modules.
#
# Public ECR repositories must be created in us-east-1. Callers must pass
# an aws.us_east_1 provider alias pointing to us-east-1.

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

locals {
  name_prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""

  # Hash both Dockerfile AND provider-versions.yaml
  # This ensures image rebuilds when provider versions change
  dockerfile_hash        = sha256(file("${path.module}/Dockerfile"))
  provider_versions_hash = sha256(file("${path.module}/../../provider-versions.yaml"))
  combined_hash          = substr(sha256("${local.dockerfile_hash}${local.provider_versions_hash}"), 0, 12)

  container_image = "${aws_ecrpublic_repository.platform.repository_uri}:${local.combined_hash}"
}

# =============================================================================
# Public ECR Repository
# =============================================================================

resource "aws_ecrpublic_repository" "platform" {
  provider = aws.us_east_1

  repository_name = "${local.name_prefix}${var.resource_name_base}/platform"
  force_destroy   = true

  tags = var.tags
}
