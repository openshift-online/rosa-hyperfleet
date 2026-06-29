# =============================================================================
# kube-applier-dynamodb Module - Input Variables
# =============================================================================

variable "mc_aws_account_id" {
  description = "AWS account ID of the management cluster. Used to grant the MC kube-applier role cross-account access via DynamoDB resource-based policies."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.mc_aws_account_id))
    error_message = "mc_aws_account_id must be a 12-digit AWS account ID"
  }
}

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
