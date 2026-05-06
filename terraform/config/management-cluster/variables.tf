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

# =============================================================================
# Maestro Configuration Variables
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

variable "maestro_agent_cert_file" {
  description = "Path to JSON file containing Maestro agent certificate material (from IoT Mint outputs)"
  type        = string
}

variable "maestro_agent_config_file" {
  description = "Path to JSON file containing Maestro agent MQTT configuration (from IoT Mint outputs)"
  type        = string
}

variable "rhobs_api_url" {
  description = "API Gateway URL for Prometheus remote_write (read from RC terraform state)"
  type        = string
  default     = ""
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
