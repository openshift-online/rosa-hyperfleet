# =============================================================================
# Required Variables
# =============================================================================

variable "tags" {
  description = "Base tags to merge with module-specific tags (function, module)"
  type        = map(string)
  default     = {}
}

variable "cluster_id" {
  description = "Regional cluster identifier for resource naming (e.g., rc01)"
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster for Pod Identity association"
  type        = string
}

# =============================================================================
# Optional Variables
# =============================================================================

variable "thanos_namespace" {
  description = "Kubernetes namespace where Thanos is deployed"
  type        = string
  default     = "thanos"
}

variable "thanos_service_account" {
  description = "Name of the Thanos service account"
  type        = string
  default     = "thanos-operator"
}

variable "metrics_retention_days" {
  description = "Number of days to retain metrics in S3"
  type        = number
  default     = 365

  validation {
    condition     = var.metrics_retention_days >= 30
    error_message = "Metrics retention must be at least 30 days for FedRAMP compliance."
  }
}

