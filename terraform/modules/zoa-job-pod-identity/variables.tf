variable "tags" {
  description = "Base tags to merge with module-specific tags (function, module)"
  type        = map(string)
  default     = {}
}

variable "management_id" {
  description = "Management cluster identifier for resource naming"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name for Pod Identity associations"
  type        = string
}

variable "zoa_outputs_bucket_arn" {
  description = "ARN of the ZOA outputs S3 bucket in the regional account"
  type        = string
}

variable "zoa_kms_key_arn" {
  description = "ARN of the ZOA KMS key in the regional account for S3 encryption"
  type        = string
}
