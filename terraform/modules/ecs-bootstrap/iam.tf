# IAM Configuration for ECS Bootstrap Module

# ECS Task Execution Role - for pulling images and writing logs
resource "aws_iam_role" "execution" {
  name = "${var.cluster_id}-bootstrap-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Attach AWS managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Role - for accessing EKS and other AWS services during bootstrap
resource "aws_iam_role" "task" {
  name = "${var.cluster_id}-bootstrap-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Policy for EKS cluster access and ArgoCD bootstrap operations
resource "aws_iam_role_policy" "task_bootstrap" {
  name = "${var.cluster_id}-bootstrap-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:DescribeNodegroup",
          "eks:ListNodegroups",
          "eks:DescribeUpdate",
          "eks:ListUpdates",
          "eks:CreateAddon",
          "eks:ListAddons"
        ]
        Resource = var.eks_cluster_arn
      },
      {
        # eks:DescribeAddon and eks:UpdateAddon operate on the addon resource type,
        # whose ARN differs from the cluster ARN and must be granted separately.
        Effect = "Allow"
        Action = [
          "eks:DescribeAddon",
          "eks:UpdateAddon"
        ]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:addon/${var.eks_cluster_name}/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:PutParameter",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.cluster_id}/*",
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/argocd/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.cluster_id}/*"
      }
    ]
  })
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# EKS Access Entry for bootstrap task role
# This provides the task role with cluster-admin access to the EKS cluster
resource "aws_eks_access_entry" "bootstrap_task" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.task.arn
  type          = "STANDARD"
}

# Associate cluster admin policy with the access entry
resource "aws_eks_access_policy_association" "bootstrap_cluster_admin" {
  cluster_name  = var.eks_cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_iam_role.task.arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bootstrap_task]
}