# =============================================================================
# HyperShift OIDC Module - Outputs
# =============================================================================

# IAM / Pod Identity
output "role_arn" {
  description = "IAM role ARN for the HyperShift operator"
  value       = aws_iam_role.hypershift_operator.arn
}

output "pod_identity_association_id" {
  description = "Pod Identity association ID for the HyperShift operator"
  value       = aws_eks_pod_identity_association.hypershift_operator.association_id
}

# Installer
output "installer_role_arn" {
  description = "IAM role ARN for the HyperShift install Job"
  value       = aws_iam_role.hypershift_installer.arn
}

output "config_secret_name" {
  description = "Secrets Manager secret name for HyperShift configuration"
  value       = aws_secretsmanager_secret.hypershift_config.name
}

# External Secrets Operator
output "external_secrets_operator_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = aws_iam_role.external_secrets_operator.arn
}

output "external_secrets_operator_pod_identity_association_id" {
  description = "Pod Identity association ID for External Secrets Operator"
  value       = aws_eks_pod_identity_association.external_secrets_operator.association_id
}