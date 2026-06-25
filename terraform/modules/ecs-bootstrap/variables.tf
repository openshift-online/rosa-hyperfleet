# Variables for ECS Bootstrap Module

variable "cluster_id" {
  description = "Unique identifier for the cluster, used as the base name for all resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where ECS bootstrap tasks will run"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for ECS task execution"
  type        = list(string)
}

variable "eks_cluster_arn" {
  description = "ARN of the EKS cluster that bootstrap tasks will configure"
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster that bootstrap tasks will configure"
  type        = string
}

variable "eks_cluster_security_group_id" {
  description = "Security group ID of the EKS cluster control plane"
  type        = string
}

variable "container_image" {
  description = "Container image for the bootstrap task (must have aws, kubectl, helm, git, jq pre-installed)"
  type        = string
}

variable "repository_url" {
  description = "Git repository URL for cluster configuration"
  type        = string
  default     = "https://github.com/openshift-online/rosa-regional-platform"
}

variable "repository_branch" {
  description = "Git branch to use for cluster configuration"
  type        = string
  default     = "main"
}

variable "thanos_kms_key_arn" {
  description = "KMS key ARN for Thanos S3 encryption"
  type        = string
  default     = ""
}

variable "loki_kms_key_arn" {
  description = "KMS key ARN for Loki S3 encryption"
  type        = string
  default     = ""
}

variable "management_clusters" {
  description = "Comma-separated colon-delimited MC entries (e.g. mc01:123456789012,mc02:987654321098)"
  type        = string
  default     = ""
}

variable "rc_aws_account_id" {
  description = "AWS account ID of the regional cluster where DynamoDB tables reside. Injected into the ArgoCD cluster secret so charts can build cross-account resource ARNs."
  type        = string
  default     = ""
}

