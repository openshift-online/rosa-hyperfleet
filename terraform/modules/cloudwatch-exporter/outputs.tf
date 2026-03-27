# =============================================================================
# CloudWatch Exporter Module - Outputs
# =============================================================================

output "role_name" {
  description = "IAM role name for CloudWatch Exporter"
  value       = aws_iam_role.cloudwatch_exporter.name
}

output "role_arn" {
  description = "IAM role ARN for CloudWatch Exporter"
  value       = aws_iam_role.cloudwatch_exporter.arn
}

output "pod_identity_association_id" {
  description = "EKS Pod Identity association ID"
  value       = aws_eks_pod_identity_association.cloudwatch_exporter.association_id
}
