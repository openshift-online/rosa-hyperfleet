variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ALB will be created"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for internet-facing ALB placement"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least 2 public subnets are required for ALB high availability."
  }
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID. For EKS Auto Mode, use the cluster_primary_security_group_id."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — required for tagging target group with eks:eks-cluster-name for Auto Mode IAM permissions"
  type        = string
}

variable "domain_name" {
  description = "FQDN for the Grafana endpoint (e.g. grafana.us-east-1.int0.rosa.devshift.net)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.domain_name))
    error_message = "domain_name must be a valid domain name."
  }
}

variable "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional domain. Used for ACM DNS validation and the Grafana alias record."
  type        = string
}
