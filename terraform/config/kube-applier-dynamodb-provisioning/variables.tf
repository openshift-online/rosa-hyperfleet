# =============================================================================
# kube-applier DynamoDB Provisioning - Variables
# =============================================================================

variable "management_cluster_id" {
  description = "Management cluster identifier (e.g., 'mc01')"
  type        = string
}

variable "mc_aws_account_id" {
  description = "AWS account ID of the management cluster. Used to grant the MC kube-applier role cross-account DynamoDB access."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.mc_aws_account_id))
    error_message = "mc_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "regional_id" {
  description = "Regional cluster identifier for backend role naming (e.g., 'regional')"
  type        = string
}

variable "enable_pitr" {
  description = "Enable Point-In-Time Recovery on DynamoDB tables. Recommended for non-ephemeral environments."
  type        = bool
  default     = false
}

# Tagging
variable "app_code" {
  description = "Application code for resource tagging and cost allocation"
  type        = string
}

variable "service_phase" {
  description = "Service phase (development, staging, production)"
  type        = string
}

variable "cost_center" {
  description = "Cost center identifier for billing and cost allocation"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
