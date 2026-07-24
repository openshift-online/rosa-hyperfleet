# =============================================================================
# Internal Application Load Balancer
#
# This ALB is created by Terraform and remains empty until ArgoCD deploys
# a TargetGroupBinding that registers pod IPs into the target group.
#
# Flow: API Gateway -> VPC Link -> ALB -> Target Group -> Pods
# =============================================================================

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "platform" {
  name               = "${var.regional_id}-api"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  tags = {
    Name = "${var.regional_id}-api"
  }
}

# -----------------------------------------------------------------------------
# Target Group
#
# Uses IP target type so LBC TargetGroupBindings register pod IPs directly.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "platform" {
  name        = "${var.regional_id}-api"
  port        = var.target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Required for TargetGroupBinding

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = var.health_check_timeout
    interval            = var.health_check_interval
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-api"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# Listener
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "platform" {
  load_balancer_arn = aws_lb.platform.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.platform.arn
  }
}

