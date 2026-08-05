# =============================================================================
# RHOBS Internal Application Load Balancer
#
# Dedicated ALB for RHOBS (observability) traffic, isolated from the Platform
# API. Uses path-based routing so only known paths reach backends; unknown or
# accidental requests get a 404 at the ALB level before hitting any service.
#
# Flow: RHOBS API Gateway -> VPC Link -> RHOBS ALB -> Thanos Receive (:19291)
#                                                   -> Thanos Query Frontend (:9090)
#                                                   -> Loki Distributor (:3100)
#                                                   -> Loki Query Frontend (:3100)
# =============================================================================

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "rhobs" {
  name               = "${var.regional_id}-rhobs"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  tags = {
    Name = "${var.regional_id}-rhobs"
  }
}

# -----------------------------------------------------------------------------
# Thanos Receive Target Group
#
# Receives Prometheus remote_write from Management Clusters via RHOBS API GW.
# Uses IP target type so LBC TargetGroupBindings register pod IPs directly.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "thanos_receive" {
  name        = "${var.regional_id}-th-recv"
  port        = var.thanos_receive_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/-/ready"
    port                = var.thanos_receive_health_port
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-th-recv"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# Listener
#
# Default action returns 404 — only explicitly routed paths reach a backend.
# This prevents unknown/accidental requests from hitting Thanos Receive.
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "rhobs" {
  load_balancer_arn = aws_lb.rhobs.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# -----------------------------------------------------------------------------
# Listener Rules
#
# Path-based routing to specific backends. Each backend gets its own rule.
# -----------------------------------------------------------------------------

resource "aws_lb_listener_rule" "thanos_receive" {
  listener_arn = aws_lb_listener.rhobs.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.thanos_receive.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/receive"]
    }
  }
}

# -----------------------------------------------------------------------------
# Thanos Query Frontend Target Group
#
# Serves PromQL queries from E2E tests and internal tooling via RHOBS API GW.
# Uses IP target type so LBC TargetGroupBindings register pod IPs directly.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "thanos_query" {
  name        = "${var.regional_id}-th-query"
  port        = var.thanos_query_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/-/ready"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-th-query"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_listener_rule" "thanos_query" {
  listener_arn = aws_lb_listener.rhobs.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.thanos_query.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/query", "/api/v1/query_range"]
    }
  }
}

resource "aws_lb_listener_rule" "thanos_rules" {
  listener_arn = aws_lb_listener.rhobs.arn
  priority     = 250

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.thanos_query.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/rules"]
    }
  }
}

# -----------------------------------------------------------------------------
# Loki Distributor Target Group
#
# Receives log push requests from MC Vector (via sigv4-proxy) and RC Vector.
# Uses IP target type so LBC TargetGroupBindings register pod IPs directly.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "loki_distributor" {
  name        = "${var.regional_id}-loki-dist"
  port        = var.loki_distributor_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/ready"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-loki-dist"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_listener_rule" "loki_push" {
  listener_arn = aws_lb_listener.rhobs.arn
  priority     = 300

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.loki_distributor.arn
  }

  condition {
    path_pattern {
      values = ["/loki/api/v1/push"]
    }
  }
}

# -----------------------------------------------------------------------------
# Loki Query Frontend Target Group
#
# Serves LogQL queries from E2E tests and internal tooling via RHOBS API GW.
# Uses IP target type so LBC TargetGroupBindings register pod IPs directly.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "loki_query_frontend" {
  name        = "${var.regional_id}-loki-qfe"
  port        = var.loki_query_frontend_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/ready"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-loki-qfe"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_listener_rule" "loki_query" {
  listener_arn = aws_lb_listener.rhobs.arn
  priority     = 400

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.loki_query_frontend.arn
  }

  condition {
    path_pattern {
      values = ["/loki/api/v1/query", "/loki/api/v1/query_range"]
    }
  }
}
