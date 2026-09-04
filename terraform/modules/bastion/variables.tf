variable "cluster_id" {
  description = "Unique identifier for the cluster, used as the base name for all resources."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster to connect to"
  type        = string
}

variable "cluster_security_group_id" {
  description = "Security group ID of the EKS cluster control plane"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the bastion will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs where the bastion task can run"
  type        = list(string)
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs. In US regions, 365 days is enforced for FedRAMP AU-11 compliance regardless of this value."
  type        = number
  default     = 30
}

variable "cpu" {
  description = "CPU units for the Fargate task (256, 512, 1024, 2048, 4096)"
  type        = string
  default     = "512"
}

variable "memory" {
  description = "Memory (MB) for the Fargate task"
  type        = string
  default     = "1024"
}

variable "log_collector_cpu" {
  description = "CPU units for the log-collector Fargate task"
  type        = string
  default     = "1024"
}

variable "log_collector_memory" {
  description = "Memory (MB) for the log-collector Fargate task"
  type        = string
  default     = "4096"
}

variable "container_image" {
  description = "Container image for the bastion task (from platform-image module)"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
