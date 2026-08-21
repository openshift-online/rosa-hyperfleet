# =============================================================================
# Management Cluster Infrastructure Variables
# =============================================================================

variable "region" {
  description = "AWS Region for infrastructure deployment"
  type        = string
}

variable "container_image" {
  description = "Public ECR image URI for platform container (used by bastion and ECS bootstrap)"
  type        = string
}

variable "target_account_id" {
  description = "Target AWS account ID for cross-account deployment. If empty, uses current account."
  type        = string
  default     = ""
}

variable "app_code" {
  description = "Application code for tagging (CMDB Application ID)"
  type        = string
}

variable "service_phase" {
  description = "Service phase for tagging (development, staging, or production)"
  type        = string
}

variable "cost_center" {
  description = "Cost center for tagging (3-digit cost center code)"
  type        = string
}

# =============================================================================
# ArgoCD Bootstrap Configuration Variables
# =============================================================================

variable "repository_url" {
  description = "Git repository URL for cluster configuration"
  type        = string
}

variable "repository_branch" {
  description = "Git branch to use for cluster configuration"
  type        = string
  default     = "main"
}

# =============================================================================
# Bastion Configuration Variables
# =============================================================================

variable "enable_bastion" {
  description = "Enable ECS Fargate bastion for break-glass/development access to the cluster"
  type        = bool
  default     = false
}

# =============================================================================
# Management Cluster Configuration Variables
# =============================================================================

variable "management_id" {
  description = "Management cluster identifier for resource naming (e.g., 'mc01' or 'xg4y-mc01' in CI)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.management_id))
    error_message = "management_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "environment" {
  description = "Environment name for tagging (e.g., 'integration', 'staging', 'production')"
  type        = string
}

variable "regional_aws_account_id" {
  description = "AWS account ID where the regional cluster and IoT Core are hosted"
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.regional_aws_account_id))
    error_message = "regional_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "dns_zone_operator_role_arn" {
  description = "ARN of the RC-side dns-zone-operator IAM role. When set, creates Pod Identity for external-dns and cert-manager."
  type        = string
  default     = ""
}

variable "zoa_outputs_bucket_arn" {
  description = "ARN of the ZOA outputs S3 bucket in the regional account (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "zoa_kms_key_arn" {
  description = "ARN of the ZOA KMS key in the regional account for S3 SSE-KMS (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "rhobs_api_url" {
  description = "API Gateway URL for Prometheus remote_write (read from RC terraform state)"
  type        = string
  default     = ""
}

# =============================================================================
# ZOA Lambda Configuration (per-VPC deployment for direct EKS access)
# =============================================================================

variable "zoa_lambda_ecr_url" {
  description = "ECR repository URL for ZOA Lambda (RC output, cross-account pull via OU policy)"
  type        = string
  default     = ""
}

variable "zoa_image_tag" {
  description = "ZOA image tag for Lambda and runner images."
  type        = string
  default     = "a3e5930"
}

variable "zoa_runner_source_image" {
  description = "Source registry image for ZOA Runner (K8s pulls directly, no ECR mirror)"
  type        = string
  default     = "quay.io/slopezz/zoa-runner"
}

variable "zoa_table_name" {
  description = "DynamoDB executions table name (in RC account)"
  type        = string
  default     = ""
}

variable "zoa_table_arn" {
  description = "DynamoDB executions table ARN (in RC account, for IAM policy)"
  type        = string
  default     = ""
}

variable "zoa_audit_table_name" {
  description = "DynamoDB audit table name (in RC account)"
  type        = string
  default     = ""
}

variable "zoa_audit_table_arn" {
  description = "DynamoDB audit table ARN (in RC account, for IAM policy)"
  type        = string
  default     = ""
}

variable "zoa_uploader_role_arn" {
  description = "ARN of the ZOA uploader role (in RC account, for STS AssumeRole)"
  type        = string
  default     = ""
}

variable "zoa_data_access_role_arn" {
  description = "ARN of the ZOA data-access role (in RC account, for cross-account DynamoDB+S3)"
  type        = string
  default     = ""
}


variable "oidc_bucket_name" {
  description = "S3 bucket name for regional OIDC discovery documents (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "oidc_bucket_arn" {
  description = "S3 bucket ARN for regional OIDC discovery documents (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "oidc_bucket_region" {
  description = "AWS region of the regional OIDC S3 bucket (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "oidc_writer_role_arn" {
  description = "ARN of the RC-side oidc-writer IAM role (MC operators assume this for OIDC S3+KMS access)"
  type        = string
  default     = ""
}

variable "oidc_cloudfront_domain" {
  description = "CloudFront domain for the regional OIDC issuer URL (read from RC terraform state)"
  type        = string
  default     = ""
}

