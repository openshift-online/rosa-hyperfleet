# =============================================================================
# Core cluster outputs
# =============================================================================

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = aws_eks_cluster.main.arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the EKS cluster"
  value       = aws_eks_cluster.main.version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for kubectl"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

# =============================================================================
# Security outputs
# =============================================================================

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster (pass-through from VPC module)"
  value       = var.cluster_security_group_id
}

output "vpc_endpoints_security_group_id" {
  description = "Security group ID for VPC endpoints (pass-through from VPC module)"
  value       = var.vpc_endpoints_security_group_id
}

output "node_security_group_id" {
  description = "EKS cluster security group ID (primary node SG, available after cluster creation)"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for EKS secrets encryption"
  value       = aws_kms_key.eks_secrets.arn
}

output "kms_key_alias" {
  description = "Alias of the KMS key used for EKS secrets encryption"
  value       = aws_kms_alias.eks_secrets.name
}

# =============================================================================
# Network outputs (pass-through from VPC module for backward compatibility)
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC (pass-through)"
  value       = var.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of private subnets (pass-through)"
  value       = var.private_subnet_ids
}

# Legacy compatibility
output "private_subnets" {
  description = "Private subnet IDs (legacy compatibility, pass-through)"
  value       = var.private_subnet_ids
}

# =============================================================================
# IAM outputs
# =============================================================================

output "cluster_iam_role_arn" {
  description = "IAM role ARN of the EKS cluster"
  value       = aws_iam_role.eks_cluster.arn
}

output "node_iam_role_arn" {
  description = "IAM role ARN for cluster nodes (Auto Mode node role or Karpenter node role, depending on enable_karpenter)"
  value       = var.enable_karpenter ? aws_iam_role.karpenter_node[0].arn : aws_iam_role.eks_auto_mode_node.arn
}

output "karpenter_controller_role_arn" {
  description = "IAM role ARN for the Karpenter controller (IRSA). Null when enable_karpenter = false."
  value       = var.enable_karpenter ? aws_iam_role.karpenter_controller[0].arn : null
}

output "karpenter_queue_url" {
  description = "SQS queue URL for Karpenter interruption handling. Null when enable_karpenter = false."
  value       = var.enable_karpenter ? aws_sqs_queue.karpenter_interruption[0].url : null
}

output "karpenter_node_instance_profile_name" {
  description = "Instance profile name for Karpenter-provisioned nodes (matches EC2NodeClass.spec.instanceProfile). Null when enable_karpenter = false."
  value       = var.enable_karpenter ? aws_iam_instance_profile.karpenter_node[0].name : null
}
