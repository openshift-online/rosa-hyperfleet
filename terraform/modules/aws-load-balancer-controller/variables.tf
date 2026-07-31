variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the LBC is deployed"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "service_account" {
  description = "Kubernetes service account name for the LBC"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
