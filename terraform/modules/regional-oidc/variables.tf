# =============================================================================
# Regional OIDC Module - Input Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier, used for resource naming"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.regional_id))
    error_message = "regional_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "mc_ou_path" {
  description = "AWS Organizations OU path for Management Cluster accounts (StringLike condition, supports wildcards)"
  type        = string
}