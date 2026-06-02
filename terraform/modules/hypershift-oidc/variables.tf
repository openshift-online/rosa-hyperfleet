# =============================================================================
# HyperShift OIDC Module - Input Variables
# =============================================================================

variable "cluster_id" {
  description = "Management cluster identifier, used for resource prefixes"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_id))
    error_message = "cluster_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "eks_cluster_name" {
  description = "EKS cluster name for Pod Identity association"
  type        = string
}

variable "oidc_bucket_name" {
  description = "S3 bucket name for OIDC discovery documents (owned by the Regional Cluster)"
  type        = string

  validation {
    condition     = length(trimspace(var.oidc_bucket_name)) > 0
    error_message = "oidc_bucket_name must be provided from RC Terraform state."
  }
}

variable "oidc_bucket_arn" {
  description = "S3 bucket ARN for OIDC discovery documents (owned by the Regional Cluster)"
  type        = string

  validation {
    condition     = length(trimspace(var.oidc_bucket_arn)) > 0
    error_message = "oidc_bucket_arn must be provided from RC Terraform state."
  }
}

variable "oidc_bucket_region" {
  description = "AWS region of the OIDC S3 bucket (owned by the Regional Cluster)"
  type        = string

  validation {
    condition     = length(trimspace(var.oidc_bucket_region)) > 0
    error_message = "oidc_bucket_region must be provided from RC Terraform state."
  }
}

variable "oidc_cloudfront_domain" {
  description = "CloudFront domain name for the OIDC issuer URL (owned by the Regional Cluster)"
  type        = string

  validation {
    condition     = length(trimspace(var.oidc_cloudfront_domain)) > 0
    error_message = "oidc_cloudfront_domain must be provided from RC Terraform state."
  }
}

variable "oidc_kms_key_arn" {
  description = "ARN of the KMS key used for OIDC S3 bucket encryption (owned by the Regional Cluster)"
  type        = string

  validation {
    condition     = length(trimspace(var.oidc_kms_key_arn)) > 0
    error_message = "oidc_kms_key_arn must be provided from RC Terraform state."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}