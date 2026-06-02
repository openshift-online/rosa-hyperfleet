# =============================================================================
# IAM Role and Pod Identity for HyperShift Operator
#
# Grants the HyperShift operator write access to the OIDC S3 bucket via
# EKS Pod Identity. The operator uploads OIDC discovery documents and
# signing keys when a HostedCluster is created.
# =============================================================================

resource "aws_iam_role" "hypershift_operator" {
  name        = "${var.cluster_id}-hypershift-operator"
  description = "IAM role for HyperShift operator to manage OIDC documents in S3"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_id}-hypershift-operator-role"
    }
  )
}

resource "aws_iam_role_policy" "hypershift_operator_s3" {
  name = "${var.cluster_id}-hypershift-operator-s3"
  role = aws_iam_role.hypershift_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        var.oidc_bucket_arn,
        "${var.oidc_bucket_arn}/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "hypershift_operator_kms" {
  name = "${var.cluster_id}-hypershift-operator-kms"
  role = aws_iam_role.hypershift_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:GenerateDataKey",
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      Resource = var.oidc_kms_key_arn
      Condition = {
        StringEquals = {
          "kms:ViaService" = "s3.${var.oidc_bucket_region}.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "hypershift_operator_ec2" {
  name = "${var.cluster_id}-hypershift-operator-ec2"
  role = aws_iam_role.hypershift_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:DescribeSecurityGroups",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:CreateTags",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:CreateVpcEndpointServiceConfiguration",
          "ec2:DescribeVpcEndpointServiceConfigurations",
          "ec2:DeleteVpcEndpointServiceConfigurations",
          "ec2:DescribeVpcEndpointServicePermissions",
          "ec2:ModifyVpcEndpointServicePermissions",
          "ec2:DescribeVpcEndpointConnections",
          "ec2:AcceptVpcEndpointConnections",
          "ec2:RejectVpcEndpointConnections",
          "ec2:DescribeVpcEndpointConnections",
          "ec2:DescribeVpcEndpoints",
          "ec2:CreateVpcEndpoint",
          "ec2:DeleteVpcEndpoints",
          "ec2:ModifyVpcEndpoint",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "hypershift_operator" {
  cluster_name    = var.eks_cluster_name
  namespace       = "hypershift"
  service_account = "operator"
  role_arn        = aws_iam_role.hypershift_operator.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_id}-hypershift-operator-pod-identity"
    }
  )
}

# =============================================================================
# IAM Role and Pod Identity for HyperShift Installer Job
#
# Grants the install Job read access to the hypershift/config secret in
# Secrets Manager via ASCP CSI driver. The Job reads the OIDC bucket name
# and passes it to `hypershift install`.
# =============================================================================

resource "aws_iam_role" "hypershift_installer" {
  name        = "${var.cluster_id}-hypershift-installer"
  description = "IAM role for HyperShift install Job to read config from Secrets Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_id}-hypershift-installer-role"
    }
  )
}

resource "aws_iam_role_policy" "hypershift_installer_secrets" {
  name = "${var.cluster_id}-hypershift-installer-secrets"
  role = aws_iam_role.hypershift_installer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = [
        aws_secretsmanager_secret.hypershift_config.arn
      ]
    }]
  })
}

resource "aws_eks_pod_identity_association" "hypershift_installer" {
  cluster_name    = var.eks_cluster_name
  namespace       = "hypershift-install"
  service_account = "hypershift-installer"
  role_arn        = aws_iam_role.hypershift_installer.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_id}-hypershift-installer-pod-identity"
    }
  )
}

# =============================================================================
# IAM Role and Pod Identity for External Secrets Operator
#
# Grants the External Secrets Operator permission to read secrets from SSM
# Parameter Store. ESO will sync these to cluster namespaces managed by
# CLM/Maestro.
#
# The operator runs in the external-secrets namespace and uses Pod Identity
# for AWS authentication.
# =============================================================================

resource "aws_iam_role" "external_secrets_operator" {
  name        = "${var.cluster_id}-external-secrets-operator"
  description = "IAM role for External Secrets Operator to read secrets from SSM Parameter Store"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_id}-external-secrets-operator-role"
    }
  )
}

resource "aws_iam_role_policy" "external_secrets_operator" {
  name = "${var.cluster_id}-external-secrets-operator-ssm"
  role = aws_iam_role.external_secrets_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:*:*:parameter/infra/*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets_operator" {
  cluster_name    = var.eks_cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets_operator.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_id}-external-secrets-operator-pod-identity"
    }
  )
}