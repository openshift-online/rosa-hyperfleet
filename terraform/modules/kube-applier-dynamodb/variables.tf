# =============================================================================
# kube-applier-dynamodb Module - Input Variables
# =============================================================================

variable "mc_name" {
  description = "Management cluster identifier (e.g., 'mc01'). Used as part of table names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.mc_name))
    error_message = "mc_name must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "rc_id" {
  description = "Regional cluster identifier for resource naming (e.g., 'regional')"
  type        = string
}

variable "aws_region" {
  description = "AWS region where DynamoDB tables will be created"
  type        = string
}

variable "enable_pitr" {
  description = "Enable Point-In-Time Recovery on DynamoDB tables. Enable for staging/production environments."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
