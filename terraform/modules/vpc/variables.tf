# =============================================================================
# VPC Module Variables
# =============================================================================

variable "resource_name_base" {
  description = "Base name for all resources (e.g., regional-cluster-x8k2)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "az_count" {
  description = "Number of AZs to span. null = all in-region AZs (needed for MC PrivateLink); set to e.g. 3 to bound the span."
  type        = number
  default     = null
}
