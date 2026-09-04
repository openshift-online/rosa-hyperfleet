variable "tags" {
  description = "Base tags to merge with module-specific tags (function, module)"
  type        = map(string)
  default     = {}
}

variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_id))
    error_message = "cluster_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment name (e.g. 'ephemeral', 'integration', 'production'). The S3 bucket force_destroy is enabled only for ephemeral environments."
  type        = string
}
