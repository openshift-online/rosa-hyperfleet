# =============================================================================
# Required Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming (e.g., regional)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., integration, stage, production)"
  type        = string
}

variable "region" {
  description = "AWS region (e.g., us-east-1)"
  type        = string
}

variable "escalation_policy_id" {
  description = "ID of an existing PagerDuty escalation policy to attach to the service"
  type        = string
}

# =============================================================================
# Optional Variables
# =============================================================================

variable "ci_prefix" {
  description = "CI prefix for ephemeral environments (e.g., xg4y). When set, prepended to the PagerDuty service name to avoid collisions."
  type        = string
  default     = ""
}

variable "service_description" {
  description = "Description for the PagerDuty service"
  type        = string
  default     = "ROSA Regional Platform alerting"
}
