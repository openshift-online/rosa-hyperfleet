# ZOA Boundary (ECS Fargate) — per-VPC audited sessions via ECS Exec.
# Merged into zoa-lambda so API/worker Lambda and boundary share one apply graph.

locals {
  boundary_container_name               = "zoa-boundary"
  boundary_effective_log_retention_days = max(365, var.boundary_log_retention_days)
  boundary_encryption_kms_arn           = var.kms_key_arn
  boundary_container_log_group_name     = "/ecs/${var.cluster_id}/zoa-boundary"
  boundary_exec_log_group_name          = "/ecs/${var.cluster_id}/zoa-boundary/ssm-sessions"
}

resource "aws_cloudwatch_log_group" "boundary" {
  name              = local.boundary_container_log_group_name
  retention_in_days = local.boundary_effective_log_retention_days
  kms_key_id        = local.boundary_encryption_kms_arn

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary-container-logs"
  })
}

resource "aws_cloudwatch_log_group" "boundary_exec" {
  name              = local.boundary_exec_log_group_name
  retention_in_days = local.boundary_effective_log_retention_days
  kms_key_id        = local.boundary_encryption_kms_arn

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary-exec-logs"
  })
}

resource "aws_security_group" "boundary" {
  name        = "${var.cluster_id}-zoa-boundary"
  description = "Security group for ZOA Boundary ECS tasks"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary"
  })
}

resource "aws_security_group_rule" "eks_ingress_from_boundary" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = var.cluster_security_group_id
  source_security_group_id = aws_security_group.boundary.id
  description              = "Allow ZOA Boundary tasks to access EKS API"
}

resource "aws_ecs_cluster" "boundary" {
  name = "${var.cluster_id}-zoa-boundary"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = local.boundary_encryption_kms_arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.boundary_exec.name
        cloud_watch_encryption_enabled = true
      }
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.boundary,
    aws_cloudwatch_log_group.boundary_exec,
  ]

  tags = local.common_tags
}

resource "null_resource" "stop_boundary_tasks" {
  depends_on = [aws_ecs_cluster.boundary]

  triggers = {
    cluster_name = aws_ecs_cluster.boundary.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      echo "Stopping any running tasks in ECS cluster ${self.triggers.cluster_name}..."
      TASKS=$(aws ecs list-tasks --cluster ${self.triggers.cluster_name} --query 'taskArns[]' --output text 2>/dev/null || true)
      if [ -n "$TASKS" ] && [ "$TASKS" != "None" ]; then
        for TASK in $TASKS; do
          echo "Stopping task: $TASK"
          aws ecs stop-task --cluster ${self.triggers.cluster_name} --task $TASK --reason "Terraform destroy" || true
        done
        echo "Waiting for tasks to stop..."
        sleep 5
      else
        echo "No running tasks found"
      fi
    EOF
  }
}
