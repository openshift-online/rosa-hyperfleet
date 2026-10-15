variable "github_repository" {
  type        = string
  description = "GitHub Repository in owner/name format (e.g., 'octocat/hello-world')"
  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in 'owner/name' format"
  }
}

variable "github_branch" {
  type        = string
  description = "GitHub Branch to track"
  default     = "main"
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection"
}

variable "region" {
  type        = string
  description = "AWS Region for the Pipeline"
  default     = "us-east-1"
}

# Optional variables for manual/single-target deployment
variable "target_account_id" {
  type        = string
  description = "Target AWS Account ID (Optional override)"
  default     = ""
}

variable "target_region" {
  type        = string
  description = "Target AWS Region (Optional override)"
  default     = ""
}

variable "regional_id" {
  type        = string
  description = "Regional cluster identifier for resource naming (e.g., 'regional' or 'eph-abc123-regional' in ephemeral envs)"
}

variable "target_environment" {
  type        = string
  description = "Target environment (integration, staging, prod)"
  default     = "integration"
}

variable "child_admin_role_name" {
  type        = string
  description = "IAM role name assumed in the target (child) account for infra apply and ArgoCD bootstrap. Defaults to the AWS Organizations role; override per environment."
  default     = "OrganizationAccountAccessRole"
}

variable "repository_url" {
  type        = string
  description = "Git repository URL for cluster configuration"
}

variable "repository_branch" {
  type        = string
  description = "Git branch to use for cluster configuration"
  default     = "main"
}

variable "codebuild_image" {
  type        = string
  description = "ECR image URI for CodeBuild projects (platform image with pre-installed tools)"
}

variable "environment_hosted_zone_id" {
  type        = string
  description = "Route53 hosted zone ID for the environment domain in the central account. Used by the regional pipeline for NS delegation."
  default     = ""
}

# =============================================================================
# Notifications Configuration
# =============================================================================

variable "slack_webhook_ssm_param" {
  type        = string
  description = "SSM Parameter Store path containing the Slack webhook URL (only required for staging, production, integration environments)"
  default     = "/rosa-regional/slack/webhook-url"
}

# Central account regions for ZOA deployment discovery SSM (module.zoa_access primary + replica).
# RC apply runs from this CodeBuild role and writes /zoa/deployments/* in both regions.
variable "zoa_central_deployments_primary_region" {
  type        = string
  description = "Central SSM region for primary /zoa/deployments/* (must match regional-cluster)."
  default     = "us-east-1"
}

variable "zoa_central_deployments_replica_region" {
  type        = string
  description = "Central SSM region for replica /zoa/deployments/* (must match regional-cluster)."
  default     = "eu-west-1"
}
