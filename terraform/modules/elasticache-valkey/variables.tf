# =============================================================================
# ElastiCache Valkey Module Variables
# =============================================================================

variable "cluster_id" {
  description = "Regional cluster identifier for resource naming (e.g. 'regional')"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where ElastiCache will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ElastiCache subnet group"
  type        = list(string)
}

variable "eks_cluster_security_group_id" {
  description = "EKS cluster additional security group ID (ingress to Valkey)"
  type        = string
}

variable "eks_cluster_primary_security_group_id" {
  description = "EKS cluster primary security group ID (Auto Mode ingress to Valkey)"
  type        = string
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t4g.micro"
}

variable "engine_version" {
  description = "Valkey engine version"
  type        = string
  default     = "9.1"
}
