# =============================================================================
# Internet-Facing ALB for Grafana OAuth Proxy
#
# This ALB is created by Terraform and remains empty until ArgoCD deploys
# a TargetGroupBinding that registers oauth2-proxy pod IPs into the target
# group. TLS is terminated at the ALB using an ACM certificate.
#
# Flow: Browser -> ALB (HTTPS/443) -> Target Group -> oauth2-proxy (HTTP/4180) -> Grafana
# =============================================================================

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Application Load Balancer (internet-facing)
# -----------------------------------------------------------------------------

resource "aws_lb" "grafana" {
  name               = "${var.regional_id}-grafana"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true

  tags = {
    Name = "${var.regional_id}-grafana"
  }
}

# -----------------------------------------------------------------------------
# Target Group
#
# Uses IP target type for TargetGroupBinding compatibility.
# EKS Auto Mode registers pod IPs when the TargetGroupBinding resource
# is created in Kubernetes.
#
# The eks:eks-cluster-name tag is REQUIRED for EKS Auto Mode —
# AmazonEKSLoadBalancingPolicy only allows RegisterTargets on tagged TGs.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "grafana" {
  name        = "${var.regional_id}-grafana"
  port        = 4180
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/ping"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-grafana"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# HTTPS Listener (443) — terminates TLS with ACM certificate
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.grafana.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# -----------------------------------------------------------------------------
# HTTP Listener (80) — redirects to HTTPS
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
