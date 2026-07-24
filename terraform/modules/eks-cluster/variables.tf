# =============================================================================
# Required variables
# =============================================================================

variable "cluster_type" {
  description = "Type of cluster: 'regional-cluster' or 'management-cluster'"
  type        = string

  validation {
    condition     = contains(["regional-cluster", "management-cluster", "fleet-db"], var.cluster_type)
    error_message = "Cluster type must be 'regional-cluster', 'management-cluster', or 'fleet-db'."
  }
}

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

variable "vpc_cidr" {
  description = "VPC CIDR block (used for security group rules)"
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
# Advanced security configuration options
# =============================================================================

variable "enable_pod_security_standards" {
  description = "Enable Kubernetes Pod Security Standards"
  type        = bool
  default     = true
}

# =============================================================================
# Karpenter configuration
# =============================================================================

variable "enable_karpenter" {
  description = "Enable OSS Karpenter instead of EKS Auto Mode. Disables Auto Mode compute, storage, and load balancing blocks. Mutually exclusive with Auto Mode."
  type        = bool
  default     = true
}

variable "ami_kms_key_arn" {
  description = "ARN of the Red Hat KMS key used to encrypt RHEL FIPS AMI EBS snapshots. When set, IAM policies granting kms:Decrypt and kms:CreateGrant on this key are added to the Karpenter node and controller roles. Leave empty to skip KMS policy creation."
  type        = string
  default     = ""
}

