# =============================================================================
# VPC Module Variables
# =============================================================================

variable "resource_name_base" {
  description = "Base name for all resources (e.g., regional-cluster-x8k2)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "List of availability zones. If empty, will auto-detect first 3 AZs in the region."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) >= 2
    error_message = "If specified, must provide at least 2 availability zones."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.0.0/18", "10.0.64.0/18", "10.0.128.0/18"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "Must provide at least 2 private subnets for high availability."
  }

  validation {
    condition = length(var.availability_zones) > 0 ? (
      length(var.private_subnet_cidrs) <= length(var.availability_zones)
      ) : (
      length(var.private_subnet_cidrs) <= 3
    )
    error_message = "Number of private subnet CIDRs cannot exceed available availability zones."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (used only for NAT gateway)"
  type        = list(string)
  default     = ["10.0.192.0/22", "10.0.196.0/22", "10.0.200.0/22"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 1
    error_message = "Must provide at least 1 public subnet for NAT gateway."
  }

  validation {
    condition = length(var.availability_zones) > 0 ? (
      length(var.public_subnet_cidrs) <= length(var.availability_zones)
      ) : (
      length(var.public_subnet_cidrs) <= 3
    )
    error_message = "Number of public subnet CIDRs cannot exceed available availability zones."
  }
}

variable "enable_vpc_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch (FedRAMP AU-12). Disable for ephemeral/CI to reduce cost."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "CloudWatch log group retention in days for VPC flow logs"
  type        = number
  default     = 365
}

# Ensure private and public subnet counts match
locals {
  subnet_count_validation = length(var.private_subnet_cidrs) == length(var.public_subnet_cidrs) ? true : tobool("Private and public subnet counts must match")
}
