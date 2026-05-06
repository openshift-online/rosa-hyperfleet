# =============================================================================
# GitHub Repository Configuration
# =============================================================================

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

variable "name_prefix" {
  type        = string
  description = "Optional prefix for resource names (e.g., CI run hash for parallel e2e runs)"
  default     = ""
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
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must be a single path segment (lowercase letters, digits, hyphen)."
  }
}

# =============================================================================
# Resource Tagging
# =============================================================================

variable "app_code" {
  description = "Application code for cost tagging (CMDB Application ID)"
  type        = string
  default     = "infra"
}

variable "service_phase" {
  description = "Service deployment phase (e.g., dev, stage, production)"
  type        = string
  default     = "dev"
}

variable "cost_center" {
  description = "Cost center code for billing"
  type        = string
  default     = "000"
}

variable "owner" {
  description = "Resource owner team identifier"
  type        = string
  default     = "placeholder"
}

variable "organization" {
  description = "Organization name for cost attribution"
  type        = string
  default     = "placeholder"
}


variable "app" {
  description = "Application identifier for resource tagging"
  type        = string
  default     = "rosa-regionality"
}

# =============================================================================
# Notifications Configuration
# =============================================================================

variable "slack_webhook_ssm_param" {
  type        = string
  description = "SSM Parameter Store path containing the Slack webhook URL (only required for staging, production, integration environments)"
  default     = "/rosa-regional/slack/webhook-url"
}

