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

variable "region" {
  type        = string
  description = "AWS Region for the Pipeline Provisioner"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment to monitor (e.g., integration, staging, production)"
  default     = "staging"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must be a single path segment (lowercase letters, digits, hyphen)."
  }
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection"
}

variable "name_prefix" {
  type        = string
  description = "Optional prefix for resource names (e.g., CI run hash for parallel e2e runs)"
  default     = ""
  validation {
    condition     = can(regex("^[a-z0-9-]*$", var.name_prefix))
    error_message = "name_prefix must contain only lowercase letters, digits, and hyphens."
  }
}

variable "platform_ecr_repo" {
  type        = string
  description = "Public ECR repository URI for the platform image"
}
