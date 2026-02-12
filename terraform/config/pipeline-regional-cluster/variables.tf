variable "github_repo_owner" {
  type        = string
  description = "GitHub Repository Owner"
}

variable "github_repo_name" {
  type        = string
  description = "GitHub Repository Name"
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

variable "target_alias" {
  type        = string
  description = "Target Alias (Optional override)"
  default     = ""
}

variable "target_environment" {
  type        = string
  description = "Target environment (integration, staging, prod)"
  default     = "integration"
}

variable "app_code" {
  type        = string
  description = "Application code for tagging"
  default     = "infra"
}

variable "service_phase" {
  type        = string
  description = "Service phase (dev, staging, prod)"
  default     = "dev"
}

variable "cost_center" {
  type        = string
  description = "Cost center for billing"
  default     = "000"
}
