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

# =============================================================================
# kube-applier Messaging Variables
# =============================================================================

variable "mc_status_sns_topic_arn" {
  description = "ARN of the MC-account SNS topic for status change notifications (read from MC management-cluster terraform state). The RC-side operator SQS queues subscribe to this topic."
  type        = string
  default     = ""
}

variable "mc_specs_queue_arn" {
  description = "ARN of the MC-account SQS queue for specs change notifications (read from MC management-cluster terraform state). The RC specs SNS topic delivers messages to this queue."
  type        = string
  default     = ""
}

variable "operator_replica_count" {
  description = "Number of hyperfleet-operator replicas. One status SQS queue is created per replica in the RC account."
  type        = number
  default     = 3
}
