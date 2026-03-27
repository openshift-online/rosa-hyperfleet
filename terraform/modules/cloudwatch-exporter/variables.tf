# =============================================================================
# CloudWatch Exporter Module - Input Variables
# =============================================================================

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the cloudwatch exporter is deployed"
  type        = string
  default     = "cloudwatch-exporter"
}

variable "service_account" {
  description = "Kubernetes service account name for the cloudwatch exporter"
  type        = string
  default     = "cloudwatch-exporter"
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
