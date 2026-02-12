# =============================================================================
# GitHub Repository Configuration
# =============================================================================

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

# =============================================================================
# AWS Configuration
# =============================================================================

variable "region" {
  type        = string
  description = "AWS Region for the Pipeline Infrastructure"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment to monitor (e.g., integration, staging, production)"
  default     = "staging"
}

