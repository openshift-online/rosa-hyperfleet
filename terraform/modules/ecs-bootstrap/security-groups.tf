# Security Groups for ECS Bootstrap Module

# Security group for bootstrap ECS tasks
resource "aws_security_group" "bootstrap_task" {
  name_prefix = "${var.cluster_id}-bootstrap-task"
  description = "Security group for ArgoCD bootstrap ECS tasks"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-bootstrap-task-sg"
  })
}

# Allow all outbound traffic for downloading tools and accessing external services
resource "aws_security_group_rule" "bootstrap_task_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.bootstrap_task.id
  description       = "Allow all outbound traffic for tool downloads and service access"
}

# Allow inbound HTTPS traffic from bootstrap tasks to EKS control plane
# Note: This rule will be added to the EKS cluster security group to allow bootstrap access
resource "aws_security_group_rule" "eks_cluster_ingress_bootstrap" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bootstrap_task.id
  security_group_id        = var.eks_cluster_security_group_id
  description              = "Allow HTTPS access from bootstrap tasks to EKS control plane"
}