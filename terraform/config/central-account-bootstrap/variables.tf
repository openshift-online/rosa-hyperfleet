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

variable "iam_role_prefix" {
  type        = string
  description = "Optional prefix for IAM role names. Defaults to name_prefix if not set. Ephemeral envs use eph-{id}, standing envs use empty string for unprefixed roles."
  default     = null
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
# Notifications Configuration
# =============================================================================

variable "enable_slack_notifications" {
  type        = bool
  description = "Enable Slack notifications for pipeline failures. When true, slack_webhook_ssm_param must point to a valid SSM parameter."
  default     = false
}

variable "slack_webhook_ssm_param" {
  type        = string
  description = "SSM Parameter Store path containing the Slack webhook URL (only used when enable_slack_notifications is true)"
  default     = "/rosa-regional/slack/webhook-url"
}

# =============================================================================
# MC Shared Role Configuration
# =============================================================================
