variable "cluster_id" {
  description = "Unique identifier for the cluster, used as the base name for all resources"
  type        = string
}

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.34"
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS control plane ENIs"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Security group ID for the EKS cluster control plane"
  type        = string
}
