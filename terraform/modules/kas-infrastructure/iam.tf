# =============================================================================
# IAM Role for KAS Server
#
# Creates an IAM role for use with EKS Pod Identity:
# - KAS server: access to database credentials in Secrets Manager
# =============================================================================

resource "aws_iam_role" "kas_server" {
  name        = "${var.regional_id}-kas-server"
  description = "IAM role for KAS server with access to database credentials"

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
      Name      = "${var.regional_id}-kas-server-role"
      Component = "kas"
    }
  )
}

# KAS server policy — Secrets Manager read access for database credentials
resource "aws_iam_role_policy" "kas_server_secrets" {
  name = "${var.regional_id}-kas-server-secrets-policy"
  role = aws_iam_role.kas_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.kas_db_credentials.arn
        ]
      }
    ]
  })
}

# Pod Identity Association for KAS server
resource "aws_eks_pod_identity_association" "kas_server" {
  cluster_name    = var.eks_cluster_name
  namespace       = "kas-system"
  service_account = "kas-sa"
  role_arn        = aws_iam_role.kas_server.arn

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-kas-server-pod-identity"
      Component = "kas"
    }
  )
}
