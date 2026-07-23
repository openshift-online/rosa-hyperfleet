# =============================================================================
# kube-applier-mc-messaging Module - Input Variables
# =============================================================================

variable "mc_name" {
  description = "Management cluster identifier (e.g., 'mc01'). Used as a prefix for resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.mc_name))
    error_message = "mc_name must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "rc_aws_account_id" {
  description = "AWS account ID of the regional cluster. Used to scope IAM and queue policies."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.rc_aws_account_id))
    error_message = "rc_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "rc_specs_sns_topic_arn" {
  description = "ARN of the specs SNS topic in the RC account that will deliver notifications to the specs SQS queue in this MC."
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS management cluster. Used for the Pod Identity association."
  type        = string
}

variable "aws_region" {
  description = "AWS region where resources are created."
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}
