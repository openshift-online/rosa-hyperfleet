provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "pipeline_provisioner" {
  source = "../pipeline-provisioner"

  github_repo_owner = var.github_repo_owner
  github_repo_name  = var.github_repo_name
  github_branch     = var.github_branch
  region            = var.region
  environment       = var.environment
}
