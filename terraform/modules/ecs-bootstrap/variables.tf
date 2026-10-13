# Variables for ECS Bootstrap Module

variable "cluster_id" {
  description = "Unique identifier for the cluster, used as the base name for all resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where ECS bootstrap tasks will run"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for ECS task execution"
  type        = list(string)
}

variable "eks_cluster_arn" {
  description = "ARN of the EKS cluster that bootstrap tasks will configure"
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster that bootstrap tasks will configure"
  type        = string
}

variable "eks_cluster_security_group_id" {
  description = "Security group ID of the EKS cluster control plane"
  type        = string
}

variable "container_image" {
  description = "Container image for the bootstrap task (must have aws, kubectl, helm, git, jq pre-installed)"
  type        = string
}

variable "repository_url" {
  description = "Git repository URL for cluster configuration"
  type        = string
  default     = "https://github.com/openshift-online/rosa-hyperfleet"
}

variable "repository_branch" {
  description = "Git branch to use for cluster configuration"
  type        = string
  default     = "main"
}

variable "thanos_kms_key_arn" {
  description = "KMS key ARN for Thanos S3 encryption"
  type        = string
  default     = ""
}

variable "loki_kms_key_arn" {
  description = "KMS key ARN for Loki S3 encryption"
  type        = string
  default     = ""
}

variable "management_clusters" {
  description = "Comma-separated colon-delimited MC entries (e.g. mc01:123456789012,mc02:987654321098)"
  type        = string
  default     = ""
}

variable "rc_aws_account_id" {
  description = "AWS account ID of the regional cluster where DynamoDB tables reside. Injected into the ArgoCD cluster secret so charts can build cross-account resource ARNs."
  type        = string
  default     = ""

  validation {
    condition     = var.rc_aws_account_id == "" || can(regex("^[0-9]{12}$", var.rc_aws_account_id))
    error_message = "rc_aws_account_id must be empty or a 12-digit AWS account ID."
  }
}

variable "redis_endpoint" {
  description = "ElastiCache Valkey endpoint for Platform API rate limiting"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# HyperFleet DB — ZOA read-only IAM role provisioning (RC only)
#
# When set, the bootstrap task provisions a dedicated Postgres role granted
# rds_iam so the ZOA Lambda can connect via RDS IAM auth. Left empty for MCs
# (which have no hyperfleet-db), skipping the step.
# -----------------------------------------------------------------------------

variable "enable_zoa_db_bootstrap" {
  description = "Whether the bootstrap task provisions the ZOA read-only IAM DB role. Enabled on the RC (which has hyperfleet-db), disabled on MCs. Must be known at plan time because it drives resource count."
  type        = bool
  default     = false
}

variable "hyperfleet_db_dsn_secret_arn" {
  description = "Secrets Manager ARN of the hyperfleet-db master DSN. Used to grant the bootstrap task access and injected as a bootstrap env var when enable_zoa_db_bootstrap is true."
  type        = string
  default     = ""
}

variable "hyperfleet_db_kms_key_arn" {
  description = "KMS key ARN encrypting the hyperfleet-db DSN secret (needed to decrypt it)."
  type        = string
  default     = ""
}

variable "hyperfleet_db_name" {
  description = "HyperFleet database name (used in GRANT CONNECT)."
  type        = string
  default     = ""
}

variable "hyperfleet_db_reader_username" {
  description = "Postgres role name for ZOA read-only IAM auth."
  type        = string
  default     = "zoa_ro"
}
