# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Current AWS region
data "aws_region" "current" {}

# TLS certificate for the EKS OIDC issuer endpoint — provides the thumbprint required
# by aws_iam_openid_connect_provider for Karpenter IRSA.
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
