# Jumphost (bastion) ECS task — long-running interactive shell for break-glass
# access to private EKS clusters via ECS Exec (SSM).

# =============================================================================
# Task Definition
# =============================================================================

resource "aws_ecs_task_definition" "bastion" {
  family                   = "${var.cluster_id}-bastion"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.container_image
      essential = true

      # Entrypoint configures kubectl and waits for connections
      # All tools are pre-installed in the container image
      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail

          echo "=== ROSA HyperFleet Bastion ==="
          echo "Starting at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
          echo ""

          echo "Pre-installed tools:"
          echo "  - aws: $(aws --version 2>&1 | head -1)"
          echo "  - kubectl: $(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion')"
          echo "  - helm: $(helm version --short)"
          echo "  - k9s: $(k9s version -s | head -1)"
          echo "  - stern: $(stern --version)"
          echo "  - yq: $(yq --version)"
          echo "  - oc: $(oc version --client -o json 2>/dev/null | jq -r '.releaseClientVersion')"
          echo "  - jq: $(jq --version)"
          echo ""

          # Configure kubectl for EKS
          echo "Configuring kubectl for cluster: $CLUSTER_NAME"
          aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

          # Verify connectivity
          echo ""
          echo "Testing cluster connectivity..."
          if kubectl cluster-info 2>/dev/null; then
            echo ""
            echo "=== Bastion ready for connections ==="
            echo ""
            echo "Connect using:"
            echo "  aws ecs execute-command \\"
            echo "    --cluster ${var.cluster_id}-bastion \\"
            echo "    --task <TASK_ID> \\"
            echo "    --container bastion \\"
            echo "    --interactive \\"
            echo "    --command '/bin/bash'"
            echo ""
          else
            echo "WARNING: Could not connect to cluster API"
          fi

          # Keep container running for ECS Exec sessions
          echo "Bastion is ready. Waiting for ECS Exec connections..."
          echo "Container will stay running until the task is stopped."
          echo ""

          # Infinite wait - container stays alive for exec sessions
          while true; do
            sleep 3600
          done
        EOF
      ]

      environment = [
        {
          name  = "CLUSTER_NAME"
          value = var.cluster_name
        },
        {
          name  = "AWS_REGION"
          value = data.aws_region.current.name
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bastion.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "bastion"
        }
      }

      # Required for ECS Exec
      linuxParameters = {
        initProcessEnabled = true
      }
    }
  ])

  tags = var.tags
}

# =============================================================================
# Task Role — EKS access + ECS Exec (SSM)
# =============================================================================

resource "aws_iam_role" "task" {
  name = "${var.cluster_id}-bastion-task"

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

  tags = var.tags
}

resource "aws_iam_role_policy" "task_eks" {
  name = "eks-access"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSListAndDescribe"
        Effect = "Allow"
        Action = [
          "eks:ListClusters",
          "eks:ListNodegroups",
          "eks:ListUpdates"
        ]
        Resource = "*"
      },
      {
        Sid    = "EKSClusterAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:DescribeNodegroup",
          "eks:DescribeUpdate",
          "eks:AccessKubernetesApi"
        ]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      }
    ]
  })
}

resource "aws_iam_role_policy" "task_ssm" {
  name = "ssm-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMMessages"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.bastion.arn}:*"
      }
    ]
  })
}

# =============================================================================
# EKS Access — Grants the jumphost task role cluster admin access
# =============================================================================

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.task.arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.task.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bastion]
}
