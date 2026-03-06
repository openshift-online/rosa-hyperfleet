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

variable "sector" {
  description = "Sector name for tagging (e.g., 'integration', 'us-gov')"
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

variable "target_alias" {
  description = "Alias for the target deployment (used for resource naming and role session identification in CloudTrail)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.target_alias))
    error_message = "target_alias must contain only lowercase letters, numbers, and hyphens"
  }
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
# Platform API Variables
# =============================================================================

variable "api_additional_allowed_accounts" {
  description = "Additional AWS account IDs allowed to access the Platform API (comma-separated). The current account is automatically included."
  type        = string
  default     = ""
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
  default     = "mq.t3.micro"
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
# DNS Configuration Variables
# =============================================================================

variable "region_dns_name" {
  description = "Base DNS name for the region (e.g., 'us-east-2.stage.rosa.example.com')"
  type        = string
}
