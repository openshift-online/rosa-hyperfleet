# =============================================================================
# DNS Pod Identity Module Variables
# =============================================================================

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

variable "dns_zone_operator_role_arn" {
  description = "ARN of the RC-side dns-zone-operator role to assume for Route53 access"
  type        = string
}
