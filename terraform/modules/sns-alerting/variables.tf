# =============================================================================
# Required Variables
# =============================================================================

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

variable "webhook_bridge_namespace" {
  description = "Kubernetes namespace where the webhook bridge service will be deployed"
  type        = string
  default     = "monitoring"
}

variable "webhook_bridge_service_account" {
  description = "Kubernetes service account name for the webhook bridge service"
  type        = string
  default     = "alert-sns-bridge"
}
