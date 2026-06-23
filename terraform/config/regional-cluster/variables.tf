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

variable "deployment_name" {
  description = "Logical deployment identifier for DNS zone naming. Equals region for normal deployments; includes a suffix for CI/ephemeral (e.g. us-east-1-xg4y)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,23}[a-z0-9])?$", var.deployment_name))
    error_message = "deployment_name must be 1-25 characters, lowercase alphanumeric or '-', starting and ending with alphanumeric."
  }
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

variable "enable_api_custom_domain" {
  description = "Enable API Gateway custom domain and ACM certificate. Adds ~20 minutes for DNS-validated certificate provisioning."
  type        = bool
  default     = false
}

variable "enable_sns_alerting" {
  description = "Enable SNS alerting for alert fan-out"
  type        = bool
  default     = false
}

variable "enable_zoa" {
  description = "Enable Zero Operator Access (ZOA) Trusted Actions infrastructure (DynamoDB, S3, KMS, IAM)"
  type        = bool
  default     = true
}

# =============================================================================
# Platform API Variables
# =============================================================================

variable "zone_shard_count" {
  description = "Number of DNS zone shards to create under the regional zone. Each shard supports ~10k records."
  type        = number
  default     = 1

  validation {
    condition     = var.zone_shard_count >= 1 && var.zone_shard_count <= 100
    error_message = "zone_shard_count must be between 1 and 100 (each shard costs $0.50/month)"
  }
}


variable "environment_domain" {
  description = "Environment domain name (e.g. int0.rosa.devshift.net). When set, creates the regional DNS zone (<deployment_name>.<environment_domain>). When null, no DNS resources are created."
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

# =============================================================================
# RHOBS API Gateway Variables
# =============================================================================

variable "rhobs_apigw_metrics_enabled" {
  description = "Enable detailed CloudWatch metrics for RHOBS API Gateway methods"
  type        = bool
  default     = true
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

# =============================================================================
# KAS Configuration Variables
# =============================================================================

variable "kas_db_instance_class" {
  description = "RDS instance class for KAS PostgreSQL database (Kine backend)"
  type        = string
  default     = "db.t4g.micro"
}

variable "kas_db_multi_az" {
  description = "Enable Multi-AZ deployment for KAS RDS (recommended for production)"
  type        = bool
  default     = false
}

variable "kas_db_deletion_protection" {
  description = "Enable deletion protection for KAS RDS instance (recommended for production)"
  type        = bool
  default     = false
}

# =============================================================================
# Regional OIDC Configuration Variables
# =============================================================================

variable "mc_ou_path" {
  description = "AWS Organizations OU path for Management Cluster accounts (StringLike condition, supports wildcards, e.g. 'o-*/r-*/ou-*/*')"
  type        = string

  validation {
    condition     = var.mc_ou_path != ""
    error_message = "mc_ou_path must be set to an AWS Organizations OU path to enable cross-account OIDC writes from Management Cluster accounts."
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

# =============================================================================
# Loki Configuration Variables
# =============================================================================

variable "loki_logs_retention_days" {
  description = "Number of days to retain logs in S3 (FedRAMP minimum: 30 days)"
  type        = number
  default     = 90
}

variable "loki_namespace" {
  description = "Kubernetes namespace where Loki is deployed"
  type        = string
  default     = "loki"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.loki_namespace))
    error_message = "Namespace must conform to DNS-1123 label: lowercase alphanumeric and '-', starting and ending with alphanumeric, max 63 characters."
  }
}

variable "loki_service_account" {
  description = "Kubernetes service account name for Loki (shared by all Loki components in Distributed mode)"
  type        = string
  default     = "loki"
}

# =============================================================================
# PagerDuty Configuration Variables
# =============================================================================

variable "enable_pagerduty" {
  description = "Enable PagerDuty service provisioning for this region"
  type        = bool
  default     = false
}

variable "pagerduty_escalation_policy_id" {
  description = "ID of an existing PagerDuty escalation policy to use for the regional service"
  type        = string
  default     = ""
}

variable "eph_prefix" {
  description = "Ephemeral environment prefix (e.g., xg4y). Passed to PagerDuty service naming to avoid collisions."
  type        = string
  default     = ""
}

# =============================================================================
# Cross-Account MC Identity
# =============================================================================

variable "management_clusters" {
  description = "Comma-separated colon-delimited MC entries (e.g. mc01:123456789012,mc02:987654321098)"
  type        = string
  default     = ""
}
