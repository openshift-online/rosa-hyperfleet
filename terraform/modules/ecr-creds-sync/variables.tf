variable "management_id" {
  description = "Management cluster identifier for resource naming"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.management_id))
    error_message = "management_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "eks_cluster_name" {
  description = "Name of the EKS management cluster"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
