# =============================================================================
# SRE UI Application Load Balancer
#
# Dedicated ALB for SRE tool access. Internal by default; internet-facing when
# enable_sre_public_access = true. Uses host-based routing so each tool gets
# its own hostname without requiring subpath configuration in the services.
#
# Flow (internal): bastion/VPC-peer -> SRE ALB -> Kubernetes service ClusterIP
#
# Hostnames (when environment_domain is set):
#   grafana.sre.{deployment_name}.{domain}    -> Grafana        :80
#   argocd.sre.{deployment_name}.{domain}     -> ArgoCD server  :443
#   prometheus.sre.{deployment_name}.{domain} -> Prometheus     :9090
#   thanos.sre.{deployment_name}.{domain}     -> Thanos QFE     :9090
#   loki.sre.{deployment_name}.{domain}       -> Loki QFE       :3100
# =============================================================================

locals {
  has_domain = var.environment_domain != null && var.environment_domain != ""
  subnet_ids = var.internal ? var.private_subnet_ids : var.public_subnet_ids


  # AWS target group names are capped at 32 chars. The longest suffix we append
  # is "-sre-prometheus" (15 chars), so cap regional_id at 17 chars.
  tg_prefix = substr(var.regional_id, 0, min(length(var.regional_id), 17))

  oidc_authorization_endpoint = "${var.oidc_issuer_url}/protocol/openid-connect/auth"
  oidc_token_endpoint         = "${var.oidc_issuer_url}/protocol/openid-connect/token"
  oidc_user_info_endpoint     = "${var.oidc_issuer_url}/protocol/openid-connect/userinfo"
}

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "sre" {
  name               = "${local.tg_prefix}-sre"
  internal           = var.internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids

  dynamic "access_logs" {
    for_each = [1]
    content {
      bucket  = aws_s3_bucket.access_logs.id
      prefix  = "alb"
      enabled = true
    }
  }

  tags = {
    Name = "${var.regional_id}-sre"
  }

  depends_on = [aws_s3_bucket_policy.access_logs]

  lifecycle {
    precondition {
      condition     = var.internal || length(var.allowed_source_cidrs) > 0
      error_message = "allowed_source_cidrs must not be empty when internal = false. Specify at least one source CIDR to restrict public access."
    }
  }
}

# -----------------------------------------------------------------------------
# Target Groups
# All use IP target type for TargetGroupBinding compatibility with EKS Auto Mode.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "grafana" {
  name        = "${local.tg_prefix}-sre-grafana"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/api/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-sre-grafana"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_target_group" "argocd" {
  name        = "${local.tg_prefix}-sre-argocd"
  port        = 443
  protocol    = "HTTPS"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/healthz"
    port                = "traffic-port"
    protocol            = "HTTPS"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-sre-argocd"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_target_group" "prometheus" {
  name        = "${local.tg_prefix}-sre-prometheus"
  port        = 9090
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
    Name                   = "${var.regional_id}-sre-prometheus"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_target_group" "thanos" {
  name        = "${local.tg_prefix}-sre-thanos"
  port        = 9090
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
    Name                   = "${var.regional_id}-sre-thanos"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_target_group" "loki" {
  name        = "${local.tg_prefix}-sre-loki"
  port        = 3100
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
    Name                   = "${var.regional_id}-sre-loki"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# Listener
#
# HTTPS when a domain + ACM certificate is available; HTTP otherwise.
# Default action returns 404 for unmatched hostnames.
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "https" {
  count = local.has_domain ? 1 : 0

  load_balancer_arn = aws_lb.sre.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.sre[0].certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "http" {
  count = local.has_domain ? 0 : 1

  load_balancer_arn = aws_lb.sre.arn
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

locals {
  listener_arn = local.has_domain ? aws_lb_listener.https[0].arn : aws_lb_listener.http[0].arn
}

# -----------------------------------------------------------------------------
# Listener Rules — host-based routing, one per service
#
# When oidc_enabled, prepend authenticate-oidc action before forwarding.
# When not oidc_enabled, forward directly.
# -----------------------------------------------------------------------------

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = local.listener_arn
  priority     = 100

  dynamic "action" {
    for_each = var.oidc_enabled ? [1] : []
    content {
      order = 1
      type  = "authenticate-oidc"
      authenticate_oidc {
        issuer                     = var.oidc_issuer_url
        authorization_endpoint     = local.oidc_authorization_endpoint
        token_endpoint             = local.oidc_token_endpoint
        user_info_endpoint         = local.oidc_user_info_endpoint
        client_id                  = var.grafana_oidc_client_id
        client_secret              = var.grafana_oidc_client_secret
        scope                      = "openid email profile"
        session_timeout            = 28800
        on_unauthenticated_request = "authenticate"
      }
    }
  }

  action {
    order            = var.oidc_enabled ? 2 : 1
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    host_header {
      values = local.has_domain ? ["grafana.sre.${var.deployment_name}.${var.environment_domain}"] : ["grafana.sre.*"]
    }
  }
}

resource "aws_lb_listener_rule" "argocd" {
  listener_arn = local.listener_arn
  priority     = 200

  dynamic "action" {
    for_each = var.oidc_enabled ? [1] : []
    content {
      order = 1
      type  = "authenticate-oidc"
      authenticate_oidc {
        issuer                     = var.oidc_issuer_url
        authorization_endpoint     = local.oidc_authorization_endpoint
        token_endpoint             = local.oidc_token_endpoint
        user_info_endpoint         = local.oidc_user_info_endpoint
        client_id                  = var.argocd_oidc_client_id
        client_secret              = var.argocd_oidc_client_secret
        scope                      = "openid email profile"
        session_timeout            = 28800
        on_unauthenticated_request = "authenticate"
      }
    }
  }

  action {
    order            = var.oidc_enabled ? 2 : 1
    type             = "forward"
    target_group_arn = aws_lb_target_group.argocd.arn
  }

  condition {
    host_header {
      values = local.has_domain ? ["argocd.sre.${var.deployment_name}.${var.environment_domain}"] : ["argocd.sre.*"]
    }
  }
}

resource "aws_lb_listener_rule" "prometheus" {
  listener_arn = local.listener_arn
  priority     = 300

  dynamic "action" {
    for_each = var.oidc_enabled ? [1] : []
    content {
      order = 1
      type  = "authenticate-oidc"
      authenticate_oidc {
        issuer                     = var.oidc_issuer_url
        authorization_endpoint     = local.oidc_authorization_endpoint
        token_endpoint             = local.oidc_token_endpoint
        user_info_endpoint         = local.oidc_user_info_endpoint
        client_id                  = var.prometheus_oidc_client_id
        client_secret              = var.prometheus_oidc_client_secret
        scope                      = "openid email profile"
        session_timeout            = 28800
        on_unauthenticated_request = "authenticate"
      }
    }
  }

  action {
    order            = var.oidc_enabled ? 2 : 1
    type             = "forward"
    target_group_arn = aws_lb_target_group.prometheus.arn
  }

  condition {
    host_header {
      values = local.has_domain ? ["prometheus.sre.${var.deployment_name}.${var.environment_domain}"] : ["prometheus.sre.*"]
    }
  }
}

resource "aws_lb_listener_rule" "thanos" {
  listener_arn = local.listener_arn
  priority     = 400

  dynamic "action" {
    for_each = var.oidc_enabled ? [1] : []
    content {
      order = 1
      type  = "authenticate-oidc"
      authenticate_oidc {
        issuer                     = var.oidc_issuer_url
        authorization_endpoint     = local.oidc_authorization_endpoint
        token_endpoint             = local.oidc_token_endpoint
        user_info_endpoint         = local.oidc_user_info_endpoint
        client_id                  = var.thanos_oidc_client_id
        client_secret              = var.thanos_oidc_client_secret
        scope                      = "openid email profile"
        session_timeout            = 28800
        on_unauthenticated_request = "authenticate"
      }
    }
  }

  action {
    order            = var.oidc_enabled ? 2 : 1
    type             = "forward"
    target_group_arn = aws_lb_target_group.thanos.arn
  }

  condition {
    host_header {
      values = local.has_domain ? ["thanos.sre.${var.deployment_name}.${var.environment_domain}"] : ["thanos.sre.*"]
    }
  }
}

resource "aws_lb_listener_rule" "loki" {
  listener_arn = local.listener_arn
  priority     = 500

  dynamic "action" {
    for_each = var.oidc_enabled ? [1] : []
    content {
      order = 1
      type  = "authenticate-oidc"
      authenticate_oidc {
        issuer                     = var.oidc_issuer_url
        authorization_endpoint     = local.oidc_authorization_endpoint
        token_endpoint             = local.oidc_token_endpoint
        user_info_endpoint         = local.oidc_user_info_endpoint
        client_id                  = var.loki_oidc_client_id
        client_secret              = var.loki_oidc_client_secret
        scope                      = "openid email profile"
        session_timeout            = 28800
        on_unauthenticated_request = "authenticate"
      }
    }
  }

  action {
    order            = var.oidc_enabled ? 2 : 1
    type             = "forward"
    target_group_arn = aws_lb_target_group.loki.arn
  }

  condition {
    host_header {
      values = local.has_domain ? ["loki.sre.${var.deployment_name}.${var.environment_domain}"] : ["loki.sre.*"]
    }
  }
}
