# =============================================================================
# Required Variables
# =============================================================================

variable "tags" {
  description = "Base tags to merge with module-specific tags (function, module)"
  type        = map(string)
  default     = {}
}

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

variable "eph_prefix" {
  description = "Ephemeral environment prefix (e.g., xg4y). When set, prepended to the PagerDuty service name to avoid collisions."
  type        = string
  default     = ""
}

variable "service_description" {
  description = "Description for the PagerDuty service"
  type        = string
  default     = "ROSA HyperFleet alerting"
}
