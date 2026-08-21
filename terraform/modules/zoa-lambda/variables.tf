# =============================================================================
# ZOA per-VPC Lambda Module Variables
# =============================================================================
# This module deploys 2 Lambdas (api + worker) in a target VPC with direct
# EKS API access. Called once for RC, once per MC.
#
# All timeouts and batch sizes are configurable here (Terraform) and are passed
# to Lambda as environment variables — tunable without code change.
# =============================================================================

variable "cluster_id" {
  description = "Unique ID for the target cluster (RC or MC). Used for Lambda naming."
  type        = string
}

# --- Container images ---

variable "lambda_image_uri" {
  description = "ECR image URI for the ZOA Lambda (minimal image from Containerfile.lambda). Use digest for deterministic deploys: <repo>:<tag>@sha256:<hash>"
  type        = string
}

variable "job_image_uri" {
  description = "ECR image URI for async K8s Jobs (full zoa-tools image from Containerfile). Contains zoa-runner + oc/kubectl for TAs that need them."
  type        = string
}

# --- VPC attachment ---

variable "private_subnet_ids" {
  description = "Private subnet IDs in the target VPC for Lambda VPC attachment"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Security group allowing access to EKS API in the target VPC"
  type        = string
}

# --- EKS connection (Lambda is NOT a Pod — needs explicit EKS auth config) ---

variable "eks_cluster_endpoint" {
  description = "Full https:// URL of the EKS API server in this VPC"
  type        = string
}

variable "eks_cluster_ca" {
  description = "Base64-encoded CA certificate for the EKS cluster"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name (used for IAM token generation via x-k8s-aws-id header)"
  type        = string
}

# --- Data layer (lives in RC account) ---

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB executions table"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the DynamoDB executions table (for IAM policy)"
  type        = string
}

variable "audit_table_name" {
  description = "Name of the DynamoDB audit table"
  type        = string
}

variable "audit_table_arn" {
  description = "ARN of the DynamoDB audit table (for IAM policy)"
  type        = string
}

variable "artifact_bucket_name" {
  description = "Name of the S3 bucket for TA artifacts"
  type        = string
}

variable "artifact_bucket_arn" {
  description = "ARN of the S3 artifact bucket (for IAM policy)"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used for encrypting DynamoDB and S3"
  type        = string
}

variable "uploader_role_arn" {
  description = "ARN of the STS uploader role for async Job credentials"
  type        = string
}

variable "data_access_role_arn" {
  description = "ARN of the cross-account data-access role in the RC account. When set, Lambda assumes this role for DynamoDB and S3 operations. Required for MC deployments where tables are in a different account."
  type        = string
  default     = ""
}


# --- Sizing and timeouts ---

variable "lambda_memory_size" {
  description = "Memory in MB for Lambda functions"
  type        = number
  default     = 512
}

variable "lambda_api_timeout" {
  description = "API Lambda timeout in seconds. Safety ceiling for sync TA execution + streaming. Per-TA timeouts are enforced in code below this."
  type        = number
  default     = 300
}

variable "lambda_worker_timeout" {
  description = "Worker Lambda timeout in seconds. Safety ceiling \u2014 real deadlines enforced in code via RECONCILER_DEADLINE_SECONDS and EXECUTION_DEADLINE_SECONDS env vars."
  type        = number
  default     = 300
}

variable "lambda_api_concurrency" {
  description = "Reserved concurrency for the API Lambda (0 = unreserved)"
  type        = number
  default     = 50
}

variable "lambda_worker_concurrency" {
  description = "Reserved concurrency for the Worker Lambda. Must be >1 to allow reconciler + concurrent TA executions. Recommended: 10 (1 for scheduled + 9 for TAs)."
  type        = number
  default     = 10
}

# --- Code-level deadlines (passed as env vars, tunable without code change) ---

variable "reconciler_deadline_seconds" {
  description = "Code-level deadline for reconciler/GC paths. If exceeded, code exits cleanly and defers to next tick. Must be < lambda_worker_timeout."
  type        = number
  default     = 55
}

variable "max_batch_per_tick" {
  description = "Max items processed per reconciler/GC tick. Remaining items deferred to next tick. Prevents timeout under high load."
  type        = number
  default     = 30
}

# --- Application tunables (passed as env vars, tunable without code change) ---

variable "write_cooldown_seconds" {
  description = "Minimum seconds between write-type TA executions for the same action+target. Prevents rapid repeated mutations."
  type        = number
  default     = 300
}

variable "max_concurrent_per_target" {
  description = "Max concurrent TA executions per target cluster. Rate-limits parallel operations against a single cluster."
  type        = number
  default     = 10
}

variable "async_scheduling_overhead_seconds" {
  description = "Extra time added to a TA's timeout when checking async execution deadline. Accounts for GSI eventual consistency + reconciler cadence + Job scheduling. TA authors set TimeoutSeconds for actual execution; this is platform overhead they don't see."
  type        = number
  default     = 180
}

# --- Kubernetes namespace ---

variable "zoa_jobs_namespace" {
  description = "Kubernetes namespace for ZOA ServiceAccounts, Jobs, and Secrets. Created by this module via the kubernetes provider."
  type        = string
  default     = "zoa-jobs"
}

# --- Feature flags ---

variable "enable_reconciler" {
  description = "Enable the EventBridge reconciler and GC schedules (disable for testing)"
  type        = bool
  default     = true
}

variable "log_level" {
  description = "Application log level for ZOA Lambda functions (debug, info, warn, error). Tunable without code change."
  type        = string
  default     = "info"
}

variable "dynamodb_ttl_days" {
  description = "DynamoDB record TTL in days (default 365 for FIPS compliance)"
  type        = number
  default     = 365
}
