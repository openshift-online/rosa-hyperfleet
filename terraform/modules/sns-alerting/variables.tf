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

variable "eks_cluster_name" {
  description = "EKS cluster name for pod identity association"
  type        = string
}

# =============================================================================
# Optional Variables
# =============================================================================

variable "alertmanager_namespace" {
  description = "Kubernetes namespace where Alertmanager is deployed"
  type        = string
  default     = "monitoring"
}

variable "alertmanager_service_account" {
  description = "Kubernetes service account name for Alertmanager"
  type        = string
  default     = "monitoring-alertmanager"
}
