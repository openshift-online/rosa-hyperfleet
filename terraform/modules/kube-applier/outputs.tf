# =============================================================================
# kube-applier Module Outputs
# =============================================================================

output "kube_applier_role_arn" {
  description = "IAM role ARN for the kube-applier-aws controller (EKS Pod Identity)"
  value       = aws_iam_role.kube_applier.arn
}
