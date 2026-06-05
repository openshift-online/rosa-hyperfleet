variable "regional_id" {
  description = "Regional identifier prefix for resource naming"
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the RC EKS cluster"
  type        = string
}

variable "mc_eks_cluster_names" {
  description = "Names of management cluster EKS clusters for Pod Identity associations"
  type        = list(string)
  default     = []
}

variable "platform_api_role_id" {
  description = "ID of the existing IAM role for Platform API (from authz module), used for policy attachment"
  type        = string
}

variable "platform_api_role_arn" {
  description = "ARN of the existing IAM role for Platform API (from authz module), used in KMS key policy"
  type        = string
}

variable "job_namespace" {
  description = "Kubernetes namespace where ZOA jobs run on MCs"
  type        = string
  default     = "zoa-jobs"
}

variable "job_service_account" {
  description = "Kubernetes service account for ZOA jobs on MCs"
  type        = string
  default     = "zoa-job-runner"
}

variable "billing_mode" {
  description = "DynamoDB billing mode"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "enable_point_in_time_recovery" {
  description = "Enable DynamoDB Point-in-Time Recovery"
  type        = bool
  default     = false
}

variable "enable_deletion_protection" {
  description = "Enable DynamoDB deletion protection"
  type        = bool
  default     = false
}

variable "output_retention_days" {
  description = "Days to retain TA outputs in S3"
  type        = number
  default     = 365
}
