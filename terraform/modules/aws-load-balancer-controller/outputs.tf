output "role_name" {
  description = "IAM role name for the AWS Load Balancer Controller"
  value       = aws_iam_role.aws_lbc.name
}

output "role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller"
  value       = aws_iam_role.aws_lbc.arn
}

output "pod_identity_association_id" {
  description = "EKS Pod Identity association ID"
  value       = aws_eks_pod_identity_association.aws_lbc.association_id
}
