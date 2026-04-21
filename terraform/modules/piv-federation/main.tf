# =============================================================================
# PIV/CAC Federation Module — FedRAMP IA-02(12) and IA-08(01)
#
# FedRAMP Moderate controls IA-02(12) (Acceptance of PIV Credentials for
# organizational users) and IA-08(01) (Acceptance of PIV Credentials for
# non-organizational users) require that the system accept PIV/CAC credentials.
#
# This module configures an AWS IAM SAML provider to accept SAML 2.0 assertions
# from a PIV-capable external identity provider (IdP) and maps those assertions
# to AWS IAM roles. The EKS cluster and API Gateway use AWS IAM as the access
# control plane; identity is established via the IdP-issued SAML assertion
# exchanged for temporary AWS credentials through the IAM SAML provider.
#
# Architecture:
#   PIV/CAC smartcard → Agency IdP (AD FS / Okta) → SAML 2.0 assertion
#   → AWS IAM SAML Provider → AWS IAM role → EKS / API Gateway
# =============================================================================

data "aws_eks_cluster" "main" { name = var.eks_cluster_name }

# =============================================================================
# IAM Identity Center External IdP SAML Configuration
#
# The external_idp_metadata_url must be set to the SAML metadata URL of the
# agency's PIV-capable identity provider (e.g., Active Directory Federation
# Services or Okta with PIV plugin). This creates the trust relationship
# that allows SAML assertions to be exchanged for AWS credentials.
# =============================================================================

resource "aws_iam_saml_provider" "piv_idp" {
  name                   = "${var.cluster_id}-piv-idp"
  saml_metadata_document = var.idp_saml_metadata_xml

  tags = {
    Name    = "${var.cluster_id}-piv-idp"
    FedRAMP = "IA-02(12)"
  }
}

# =============================================================================
# IAM Role for SAML Federation — Cluster Operators (Org Users, IA-02(12))
# =============================================================================

resource "aws_iam_role" "piv_operator" {
  name        = "${var.cluster_id}-piv-operator"
  description = "Role assumed by organizational users authenticating via PIV/CAC through SAML federation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_saml_provider.piv_idp.arn
        }
        Action = "sts:AssumeRoleWithSAML"
        Condition = {
          StringEquals = {
            "SAML:aud" = "https://signin.aws.amazon.com/saml"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "${var.cluster_id}-piv-operator"
    FedRAMP = "IA-02(12)"
  }
}

# Grant EKS cluster read access to allow kubectl authentication
resource "aws_iam_role_policy" "piv_operator_eks" {
  name = "eks-access"
  role = aws_iam_role.piv_operator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:ListClusters"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = data.aws_eks_cluster.main.arn
      }
    ]
  })
}

# =============================================================================
# IAM Role for SAML Federation — Non-Org Users (IA-08(01))
# =============================================================================

resource "aws_iam_role" "piv_customer" {
  name        = "${var.cluster_id}-piv-customer"
  description = "Role assumed by non-organizational (customer) users authenticating via PIV/CAC"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_saml_provider.piv_idp.arn
        }
        Action = "sts:AssumeRoleWithSAML"
        Condition = {
          StringEquals = {
            "SAML:aud" = "https://signin.aws.amazon.com/saml"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "${var.cluster_id}-piv-customer"
    FedRAMP = "IA-08(01)"
  }
}

# =============================================================================
# EKS Access Entry — Map SAML-federated role to Kubernetes RBAC
# =============================================================================

resource "aws_eks_access_entry" "piv_operator" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.piv_operator.arn
  type          = "STANDARD"

  tags = {
    FedRAMP = "IA-02(12)"
  }
}

resource "aws_eks_access_policy_association" "piv_operator_view" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.piv_operator.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_access_entry" "piv_customer" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.piv_customer.arn
  type          = "STANDARD"

  tags = {
    FedRAMP = "IA-08(01)"
  }
}

resource "aws_eks_access_policy_association" "piv_customer_view" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.piv_customer.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }
}
