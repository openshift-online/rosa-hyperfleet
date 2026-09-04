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

variable "loki_namespace" {
  description = "Kubernetes namespace where Loki is deployed"
  type        = string
  default     = "loki"
}

variable "loki_service_account" {
  description = "Name of the Loki service account (used by all Loki pods in Distributed mode)"
  type        = string
  default     = "loki"
}

variable "logs_retention_days" {
  description = "Number of days to retain logs in S3"
  type        = number
  default     = 90

  validation {
    condition     = var.logs_retention_days >= 30
    error_message = "Logs retention must be at least 30 days for FedRAMP compliance."
  }
}
