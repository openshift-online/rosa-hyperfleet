# =============================================================================
# kube-applier Module - Input Variables
# =============================================================================

variable "management_id" {
  description = "Management cluster identifier for resource naming (e.g., 'mc01')"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.management_id))
    error_message = "management_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "eks_cluster_name" {
  description = "Name of the EKS management cluster"
  type        = string
}

variable "rc_aws_account_id" {
  description = "AWS account ID of the regional cluster where DynamoDB tables reside"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.rc_aws_account_id))
    error_message = "rc_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "aws_region" {
  description = "AWS region where DynamoDB tables reside (must match the RC region)"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
