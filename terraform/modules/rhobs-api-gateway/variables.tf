# =============================================================================
# Required Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ALB and VPC Link will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ALB and VPC Link placement"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required for ALB high availability."
  }
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID - ALB needs to send traffic to pods via this SG"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name - used to tag target groups with eks:eks-cluster-name"
  type        = string
}

# =============================================================================
# API Gateway Configuration
# =============================================================================

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"
}

variable "metrics_enabled" {
  description = "Enable detailed CloudWatch metrics for all API methods"
  type        = bool
  default     = true
}

# =============================================================================
# Target Group Configuration
# =============================================================================

variable "thanos_receive_port" {
  description = "Thanos Receive remote-write port"
  type        = number
  default     = 19291

  validation {
    condition     = var.thanos_receive_port >= 1 && var.thanos_receive_port <= 65535
    error_message = "Thanos receive port must be between 1 and 65535."
  }
}

variable "thanos_receive_health_port" {
  description = "Thanos Receive HTTP port serving /-/ready (distinct from the remote-write port)"
  type        = number
  default     = 10902

  validation {
    condition     = var.thanos_receive_health_port >= 1 && var.thanos_receive_health_port <= 65535
    error_message = "Thanos health check port must be between 1 and 65535."
  }
}

variable "thanos_query_port" {
  description = "Thanos Query Frontend HTTP port"
  type        = number
  default     = 9090

  validation {
    condition     = var.thanos_query_port >= 1 && var.thanos_query_port <= 65535
    error_message = "Thanos query port must be between 1 and 65535."
  }
}

# =============================================================================
# Loki Target Group Configuration
# =============================================================================

variable "loki_distributor_port" {
  description = "Loki Distributor HTTP port for log push"
  type        = number
  default     = 3100

  validation {
    condition     = var.loki_distributor_port >= 1 && var.loki_distributor_port <= 65535
    error_message = "Loki distributor port must be between 1 and 65535."
  }
}

variable "loki_query_frontend_port" {
  description = "Loki Query Frontend HTTP port"
  type        = number
  default     = 3100

  validation {
    condition     = var.loki_query_frontend_port >= 1 && var.loki_query_frontend_port <= 65535
    error_message = "Loki query frontend port must be between 1 and 65535."
  }
}
