variable "region" {
  description = "AWS region where DynamoDB tables will be created"
  type        = string
}

variable "mc_name" {
  description = "Management cluster identifier (e.g., 'mc01')"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.mc_name))
    error_message = "mc_name must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "mc_aws_account_id" {
  description = "AWS account ID of the management cluster"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.mc_aws_account_id))
    error_message = "mc_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "rc_id" {
  description = "Regional cluster identifier (e.g., 'regional')"
  type        = string
}

variable "enable_pitr" {
  description = "Enable Point-In-Time Recovery on DynamoDB tables"
  type        = bool
  default     = false
}

variable "app_code" {
  description = "Application code for tagging"
  type        = string
}

variable "service_phase" {
  description = "Service phase for tagging"
  type        = string
}

variable "cost_center" {
  description = "Cost center for tagging"
  type        = string
}

variable "environment" {
  description = "Environment name (staging, production, etc.)"
  type        = string
}
