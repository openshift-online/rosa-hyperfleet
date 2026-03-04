data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Shared GitHub CodeStar Connection
# The bootstrap script creates the connection (if needed) and waits for it to
# be authorized, then imports it here so terraform tracks it in state.
# During teardown, `terraform state rm` removes it before destroy so the
# connection persists across CI runs.
resource "aws_codestarconnections_connection" "github" {
  name          = "rosa-regional-github-shared"
  provider_type = "GitHub"
}

# Platform Image ECR Repository
module "platform_image" {
  source = "../../modules/platform-image"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  resource_name_base = "rosa-regional"
  name_prefix        = var.name_prefix
  tags = {
    Name        = "rosa-regional-platform-image"
    Environment = var.environment
  }
}

module "pipeline_provisioner" {
  source = "../../modules/pipeline-provisioner"

  github_repository     = var.github_repository
  github_branch         = var.github_branch
  region                = var.region
  environment           = var.environment
  github_connection_arn = aws_codestarconnections_connection.github.arn
  codebuild_image       = module.platform_image.container_image
  platform_ecr_repo     = module.platform_image.ecr_repository_url
  name_prefix           = var.name_prefix
}
