# =============================================================================
# ecr-creds-sync Module
#
# Creates the IAM role and EKS Pod Identity association for the ECR credentials
# synchronizer running on a Management Cluster.
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      function  = "credentials"
      module    = "ecr-creds-sync"
      ManagedBy = "terraform"
    }
  )
}

resource "aws_iam_role" "ecr_creds_sync" {
  name        = "${var.management_id}-ecr-creds-sync"
  description = "IAM role for the ecr-creds-sync controller to obtain ECR authorization tokens"

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
      Name = "${var.management_id}-ecr-creds-sync-role"
    }
  )
}

resource "aws_iam_role_policy" "ecr_authorization" {
  name = "${var.management_id}-ecr-authorization"
  role = aws_iam_role.ecr_creds_sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "GetECRAuthorizationToken"
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "ecr_creds_sync" {
  cluster_name    = var.eks_cluster_name
  namespace       = "ecr-creds-sync"
  service_account = "ecr-creds-sync"
  role_arn        = aws_iam_role.ecr_creds_sync.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.management_id}-ecr-creds-sync-pod-identity"
    }
  )
}
