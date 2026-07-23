# =============================================================================
# kube-applier-rc-messaging Module - Input Variables
# =============================================================================

variable "mc_name" {
  description = "Management cluster identifier (e.g., 'mc01'). Used as a prefix for per-MC resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.mc_name))
    error_message = "mc_name must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "mc_aws_account_id" {
  description = "AWS account ID of the management cluster. Used to scope IAM and queue policies."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.mc_aws_account_id))
    error_message = "mc_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "rc_id" {
  description = "Regional cluster identifier for resource naming (e.g., 'regional'). Used to name the operator SQS queues."
  type        = string
}

variable "aws_region" {
  description = "AWS region where resources are created."
  type        = string
}

variable "operator_replica_count" {
  description = "Number of hyperfleet-operator pod replicas. One SQS queue is created per replica so that each pod drains its own queue without competing consumers."
  type        = number
  default     = 3

  validation {
    condition     = var.operator_replica_count >= 1 && var.operator_replica_count <= 10
    error_message = "operator_replica_count must be between 1 and 10"
  }
}

variable "mc_status_sns_topic_arn" {
  description = "ARN of the status SNS topic in the MC account. The RC-side SQS queues subscribe to this topic for cross-account delivery."
  type        = string
}

variable "mc_specs_queue_arn" {
  description = "ARN of the specs SQS queue in the MC account. The RC specs SNS topic subscribes this queue so the operator's publish triggers delivery to kube-applier."
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}
