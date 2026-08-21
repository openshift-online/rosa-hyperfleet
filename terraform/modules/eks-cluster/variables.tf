# =============================================================================
# Required variables
# =============================================================================

variable "cluster_id" {
  description = "Unique identifier for the cluster, used as the base name for all resources."
  type        = string
}

# =============================================================================
# Kubernetes configuration
# =============================================================================

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.34"

  validation {
    condition     = can(regex("^1\\.(2[89]|3[0-9])$", var.cluster_version))
    error_message = "Cluster version must be more modern."
  }
}

# =============================================================================
# VPC inputs (from vpc module)
# =============================================================================

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS worker nodes"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Pre-created security group ID for EKS cluster control plane"
  type        = string
}

variable "vpc_endpoints_security_group_id" {
  description = "Pre-created security group ID for VPC endpoints"
  type        = string
}

# =============================================================================
# Karpenter configuration
# =============================================================================

variable "ami_kms_key_arn" {
  description = "ARN of the Red Hat KMS key used to encrypt RHEL FIPS AMI EBS snapshots. When set, an IAM policy granting kms:CreateGrant and kms:DescribeKey on this key is added to the Karpenter controller role. Leave empty to skip KMS policy creation."
  type        = string
  default     = ""
}

