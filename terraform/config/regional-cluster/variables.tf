# =============================================================================
# Regional Cluster Infrastructure Variables
# =============================================================================

variable "regional_id" {
  description = "Deterministic regional cluster identifier for resource naming (e.g., 'regional' or 'xg4y-regional' in CI)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.regional_id))
    error_message = "regional_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "environment" {
  description = "Environment name for tagging (e.g., 'integration', 'staging', 'production')"
  type        = string
}

variable "region" {
  description = "AWS Region for infrastructure deployment"
  type        = string
}

variable "container_image" {
  description = "Public ECR image URI for platform container (used by bastion and ECS bootstrap)"
  type        = string

  validation {
    condition     = length(var.container_image) > 0
    error_message = "container_image must be a non-empty ECR image URI"
  }
}

variable "target_account_id" {
  description = "Target AWS account ID for cross-account deployment. If empty, uses current account."
  type        = string
  default     = ""
}

variable "central_aws_profile" {
  description = "AWS CLI profile for central account credentials. Set by pipeline, empty for local dev."
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

variable "owner" {
  description = "Resource owner team identifier"
  type        = string
}

variable "organization" {
  description = "Organization name for cost attribution"
  type        = string
}

variable "app" {
  description = "Application identifier for resource tagging"
  type        = string
  default     = "rosa-regionality"
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

variable "enable_cloudtrail" {
  description = "Enable CloudTrail audit logging (FedRAMP AU-12). Disable for ephemeral/CI to avoid per-account trail limits."
  type        = bool
  default     = false
}

# =============================================================================
# Platform API Variables
# =============================================================================

variable "api_additional_allowed_accounts" {
  description = "Additional AWS account IDs allowed to access the Platform API (comma-separated). The current account is automatically included."
  type        = string
  default     = ""
}

variable "environment_domain" {
  description = "Environment domain name (e.g. int0.rosa.devshift.net). When set, creates the regional DNS zone (<region>.<environment_domain>) and custom API domain (api.<region>.<environment_domain>). When null, no DNS resources are created."
  type        = string
  default     = null
}

variable "environment_hosted_zone_id" {
  description = "Route53 hosted zone ID for the environment domain (e.g. the zone for int0.rosa.devshift.net) in the central account. Used to create NS delegation records for the regional zone. When null, delegation must be done externally."
  type        = string
  default     = null
}

# =============================================================================
# API Gateway Method Settings Variables
# =============================================================================

variable "api_metrics_enabled" {
  description = "Enable detailed CloudWatch metrics for all API methods"
  type        = bool
  default     = true
}

variable "api_logging_level" {
  description = "CloudWatch logging level for API methods (OFF, ERROR, INFO)"
  type        = string
  default     = "ERROR"
}

variable "api_data_trace_enabled" {
  description = "Enable full request/response data tracing in CloudWatch logs (avoid in production)"
  type        = bool
  default     = false
}

variable "api_throttling_burst_limit" {
  description = "Maximum concurrent requests allowed (burst) for API Gateway methods"
  type        = number
  default     = 500
}

variable "api_throttling_rate_limit" {
  description = "Steady-state requests per second allowed for API Gateway methods"
  type        = number
  default     = 100
}

# Maestro Configuration Variables
# =============================================================================

variable "maestro_db_instance_class" {
  description = "RDS instance class for Maestro PostgreSQL database"
  type        = string
  default     = "db.t4g.micro"
}

variable "maestro_db_multi_az" {
  description = "Enable Multi-AZ deployment for Maestro RDS (recommended for production)"
  type        = bool
  default     = false
}

variable "maestro_db_deletion_protection" {
  description = "Enable deletion protection for Maestro RDS instance (recommended for production)"
  type        = bool
  default     = false
}

variable "maestro_mqtt_topic_prefix" {
  description = "Prefix for MQTT topics used by Maestro"
  type        = string
  default     = "maestro/consumers"
}

variable "iot_log_level" {
  description = "AWS IoT Core default log level (DISABLED, ERROR, WARN, INFO, DEBUG)"
  type        = string
  default     = "WARN"

  validation {
    condition     = contains(["DISABLED", "ERROR", "WARN", "INFO", "DEBUG"], var.iot_log_level)
    error_message = "iot_log_level must be one of: DISABLED, ERROR, WARN, INFO, DEBUG"
  }
}

# =============================================================================
# Authorization Configuration Variables
# =============================================================================

variable "authz_billing_mode" {
  description = "DynamoDB billing mode for authz tables"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "authz_enable_pitr" {
  description = "Enable point-in-time recovery for authz DynamoDB tables (recommended for production)"
  type        = bool
  default     = false
}

variable "authz_deletion_protection" {
  description = "Enable deletion protection for authz DynamoDB tables (recommended for production)"
  type        = bool
  default     = false
}

variable "authz_frontend_api_namespace" {
  description = "Kubernetes namespace for Platform API"
  type        = string
  default     = "platform-api"
}

variable "authz_frontend_api_service_account" {
  description = "Kubernetes service account name for Platform API"
  type        = string
  default     = "platform-api-sa"
}

# =============================================================================
# HyperFleet Configuration Variables
# =============================================================================

variable "hyperfleet_db_instance_class" {
  description = "RDS instance class for HyperFleet PostgreSQL database"
  type        = string
  default     = "db.t4g.micro"
}

variable "hyperfleet_db_multi_az" {
  description = "Enable Multi-AZ deployment for HyperFleet RDS (recommended for production)"
  type        = bool
  default     = false
}

variable "hyperfleet_db_deletion_protection" {
  description = "Enable deletion protection for HyperFleet RDS instance (recommended for production)"
  type        = bool
  default     = false
}

variable "hyperfleet_mq_instance_type" {
  description = "Amazon MQ instance type for HyperFleet RabbitMQ broker"
  type        = string
  default     = "mq.m5.large"
}

variable "hyperfleet_mq_deployment_mode" {
  description = "Amazon MQ deployment mode (SINGLE_INSTANCE or CLUSTER_MULTI_AZ)"
  type        = string
  default     = "SINGLE_INSTANCE"

  validation {
    condition     = contains(["SINGLE_INSTANCE", "CLUSTER_MULTI_AZ"], var.hyperfleet_mq_deployment_mode)
    error_message = "Deployment mode must be SINGLE_INSTANCE or CLUSTER_MULTI_AZ"
  }
}

variable "node_instance_types" {
  description = "List of EC2 instance types for worker nodes (configurable via config.yaml terraform_vars)"
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "Must specify at least one instance type."
  }
}

# =============================================================================
# Thanos Configuration Variables
# =============================================================================

variable "thanos_metrics_retention_days" {
  description = "Number of days to retain metrics in S3 (FedRAMP minimum: 30 days)"
  type        = number
  default     = 365
}

variable "thanos_namespace" {
  description = "Kubernetes namespace where Thanos is deployed"
  type        = string
  default     = "thanos"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.thanos_namespace))
    error_message = "Namespace must conform to DNS-1123 label: lowercase alphanumeric and '-', starting and ending with alphanumeric, max 63 characters."
  }
}

variable "thanos_service_account" {
  description = "Kubernetes service account name for Thanos"
  type        = string
  default     = "thanos-operator"
}


