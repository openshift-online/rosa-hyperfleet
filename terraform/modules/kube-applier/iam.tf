# =============================================================================
# kube-applier IAM Role and Policies (MC account)
#
# The controller needs cross-account DynamoDB access to tables in the RC account.
# Permissions are scoped to only the tables for this specific MC:
#   Specs tables (mc-{mc}-specs-*): read-only + DynamoDB Streams
#   Status tables (mc-{mc}-status-*): read-write
# =============================================================================

# IAM role for kube-applier with EKS Pod Identity
resource "aws_iam_role" "kube_applier" {
  name        = "${var.management_id}-kube-applier"
  description = "IAM role for kube-applier-aws controller with access to DynamoDB tables in the RC account"

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
      Name = "${var.management_id}-kube-applier-role"
    }
  )
}

# Policy: Read specs tables + DynamoDB Streams (for the DynamoDB Streams-backed informers)
resource "aws_iam_role_policy" "kube_applier_specs" {
  name = "${var.management_id}-kube-applier-specs"
  role = aws_iam_role.kube_applier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SpecsTableReadOnly"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Scan",
          "dynamodb:Query",
        ]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${var.rc_aws_account_id}:table/mc-${var.management_id}-specs-*",
        ]
      },
      {
        Sid    = "SpecsTableStreams"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:ListStreams",
        ]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${var.rc_aws_account_id}:table/mc-${var.management_id}-specs-*",
          "arn:aws:dynamodb:${var.aws_region}:${var.rc_aws_account_id}:table/mc-${var.management_id}-specs-*/stream/*",
        ]
      },
    ]
  })
}

# Policy: Read-write status tables (controller writes results back here)
resource "aws_iam_role_policy" "kube_applier_status" {
  name = "${var.management_id}-kube-applier-status"
  role = aws_iam_role.kube_applier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "StatusTableReadWrite"
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
      ]
      Resource = [
        "arn:aws:dynamodb:${var.aws_region}:${var.rc_aws_account_id}:table/mc-${var.management_id}-status-*",
      ]
    }]
  })
}

# EKS Pod Identity Association
# Links the kube-applier ServiceAccount in the kube-applier-system namespace
# to the IAM role above, providing DynamoDB credentials without static secrets.
resource "aws_eks_pod_identity_association" "kube_applier" {
  cluster_name    = var.eks_cluster_name
  namespace       = "kube-applier"
  service_account = "kube-applier"
  role_arn        = aws_iam_role.kube_applier.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.management_id}-kube-applier-pod-identity"
    }
  )
}
