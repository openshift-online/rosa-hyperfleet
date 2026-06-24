# =============================================================================
# kube-applier DynamoDB Provisioning - Variables
# =============================================================================

variable "management_cluster_id" {
  description = "Management cluster identifier (e.g., 'mc01')"
  type        = string
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
