# =============================================================================
# Regional OIDC Module - Outputs
# =============================================================================

output "cloudfront_domain_name" {
  description = "CloudFront domain name — this is the stable OIDC issuer base URL (prefix with https://)"
  value       = aws_cloudfront_distribution.oidc.domain_name
}

output "bucket_name" {
  description = "S3 bucket name for OIDC discovery documents"
  value       = aws_s3_bucket.oidc.id
}

output "bucket_arn" {
  description = "S3 bucket ARN for OIDC discovery documents"
  value       = aws_s3_bucket.oidc.arn
}

output "bucket_region" {
  description = "AWS region where the OIDC S3 bucket is deployed"
  value       = data.aws_region.current.region
}

output "oidc_writer_role_arn" {
  description = "ARN of the oidc-writer IAM role — MC operators assume this for S3+KMS access"
  value       = aws_iam_role.oidc_writer.arn
}
