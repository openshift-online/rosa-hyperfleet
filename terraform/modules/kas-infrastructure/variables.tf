# =============================================================================
# KAS Infrastructure Module - Variables
#
# This module creates AWS resources for the Kubernetes API Server (KAS)
# backed by Kine with PostgreSQL storage:
# - RDS PostgreSQL (Kine state storage)
# - Secrets Manager (database credentials)
# - IAM roles (Pod Identity for the KAS server pod)
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where resources will be deployed"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for RDS deployment"
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "EKS cluster name for Pod Identity associations"
  type        = string
}

variable "eks_cluster_security_group_id" {
  description = "EKS cluster additional security group ID for RDS access"
  type        = string
}

variable "eks_cluster_primary_security_group_id" {
  description = "EKS cluster primary security group ID for RDS access (used by Auto Mode nodes)"
  type        = string
}

variable "bastion_enabled" {
  description = "Whether the bastion host is enabled (used for count to avoid unknown value issues)"
  type        = bool
  default     = false
}

variable "bastion_security_group_id" {
  description = "Optional bastion security group ID for RDS access (if bastion is enabled)"
  type        = string
  default     = null

  validation {
    condition     = !var.bastion_enabled || (var.bastion_security_group_id != null && var.bastion_security_group_id != "")
    error_message = "bastion_security_group_id must be set when bastion_enabled is true."
  }
}

# =============================================================================
# Database Configuration
# =============================================================================

variable "db_instance_class" {
  description = "RDS instance class for KAS PostgreSQL database (Kine backend)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS instance in GB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "18"

  validation {
    condition     = can(regex("^[0-9]+$", var.db_engine_version))
    error_message = "db_engine_version must be a major version only (e.g., \"18\")."
  }
}

variable "db_name" {
  description = "Name of the database to create"
  type        = string
  default     = "kas"
}

variable "db_username" {
  description = "Master username for the database"
  type        = string
  default     = "kas_admin"
}

variable "db_multi_az" {
  description = "Enable Multi-AZ deployment for RDS (production use)"
  type        = bool
  default     = false
}

variable "db_backup_retention_period" {
  description = "Number of days to retain automated backups"
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Enable deletion protection for RDS instance"
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip final snapshot when deleting RDS instance"
  type        = bool
  default     = true
}

# =============================================================================
# Tagging
# =============================================================================

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
