output "saml_provider_arn" {
  description = "ARN of the IAM SAML provider for the PIV/CAC IdP"
  value       = aws_iam_saml_provider.piv_idp.arn
}

output "piv_operator_role_arn" {
  description = "ARN of the IAM role for PIV-authenticated organizational operators"
  value       = aws_iam_role.piv_operator.arn
}

output "piv_customer_role_arn" {
  description = "ARN of the IAM role for PIV-authenticated non-organizational (customer) users"
  value       = aws_iam_role.piv_customer.arn
}
