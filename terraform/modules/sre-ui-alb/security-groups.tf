# =============================================================================
# Security Groups
#
# One security group for the SRE ALB:
# - Ingress HTTPS (443) from VPC CIDR (internal) or allowed_source_cidrs (public; must be non-empty)
# - Egress to node SG on container ports: 3000 (Grafana), 8080 (ArgoCD), 9090 (Prometheus/Thanos), 3100 (Loki)
#
# Node SG ingress rules allow the ALB to reach pods on each service port.
# =============================================================================

# -----------------------------------------------------------------------------
# ALB Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.regional_id}-sre-alb"
  description = "Security group for SRE UI ALB"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = false

  tags = {
    Name = "${var.regional_id}-sre-alb"
  }
}

# Ingress: HTTPS from VPC CIDR (internal mode)
resource "aws_vpc_security_group_ingress_rule" "alb_https_from_vpc" {
  count = var.internal ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS from VPC (internal access)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

# Ingress: HTTP from VPC CIDR (internal, no-domain fallback)
resource "aws_vpc_security_group_ingress_rule" "alb_http_from_vpc" {
  count = var.internal ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from VPC (internal access, no-domain fallback)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = var.vpc_cidr
}

# Ingress: HTTPS from allowed CIDRs (public mode)
resource "aws_vpc_security_group_ingress_rule" "alb_https_from_cidr" {
  count = var.internal ? 0 : length(var.allowed_source_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS from ${var.allowed_source_cidrs[count.index]}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.allowed_source_cidrs[count.index]
}


# Egress: to Grafana pods (port 3000 — container port behind service port 80)
resource "aws_vpc_security_group_egress_rule" "alb_to_http_services" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to Grafana pods (port 3000)"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = var.node_security_group_id
}

# Egress: to ArgoCD pods (port 8080 — container port behind service port 443)
resource "aws_vpc_security_group_egress_rule" "alb_to_argocd" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to ArgoCD pods (port 8080)"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = var.node_security_group_id
}

# Egress: to Prometheus and Thanos pods (port 9090)
resource "aws_vpc_security_group_egress_rule" "alb_to_metrics_services" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to Prometheus and Thanos QFE pods (port 9090)"
  ip_protocol                  = "tcp"
  from_port                    = 9090
  to_port                      = 9090
  referenced_security_group_id = var.node_security_group_id
}

# Egress: to Loki pods (port 3100)
resource "aws_vpc_security_group_egress_rule" "alb_to_loki" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to Loki Query Frontend pods (port 3100)"
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
  referenced_security_group_id = var.node_security_group_id
}

# -----------------------------------------------------------------------------
# Node Security Group Ingress Rules
#
# Allow SRE ALB traffic to reach pods on each service port.
# For EKS Auto Mode, targets the cluster_primary_security_group_id.
# -----------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_http" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow SRE ALB traffic to Grafana pods (port 3000)"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_argocd" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow SRE ALB traffic to ArgoCD pods (port 8080)"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_metrics" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow SRE ALB traffic to Prometheus and Thanos QFE pods (port 9090)"
  ip_protocol                  = "tcp"
  from_port                    = 9090
  to_port                      = 9090
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_loki" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow SRE ALB traffic to Loki Query Frontend pods (port 3100)"
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
  referenced_security_group_id = aws_security_group.alb.id
}
