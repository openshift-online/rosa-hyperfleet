# =============================================================================
# DNS Pod Identity (MC-side)
#
# Pod Identity roles for external-dns and cert-manager on MCs. Each pod
# assumes a local role that can AssumeRole to the RC-side dns-zone-operator
# role for Route53 access to zone shards.
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      function = "dns"
      module   = "dns-pod-identity"
    }
  )
}

resource "aws_iam_role" "dns_operator" {
  name        = "${var.management_id}-dns-operator"
  description = "Pod Identity role for external-dns and cert-manager to assume the RC dns-zone-operator role"

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

  tags = merge(local.common_tags, {
    Name = "${var.management_id}-dns-operator"
  })
}

resource "aws_iam_role_policy" "assume_dns_zone_operator" {
  name = "${var.management_id}-assume-dns-zone-operator"
  role = aws_iam_role.dns_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
      Resource = var.dns_zone_operator_role_arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = var.eks_cluster_name
  namespace       = "hypershift"
  service_account = "external-dns"
  role_arn        = aws_iam_role.dns_operator.arn

  tags = merge(local.common_tags, {
    Name = "${var.management_id}-external-dns-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "cert_manager" {
  cluster_name    = var.eks_cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"
  role_arn        = aws_iam_role.dns_operator.arn

  tags = merge(local.common_tags, {
    Name = "${var.management_id}-cert-manager-pod-identity"
  })
}
