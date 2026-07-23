# =============================================================================
# Security Groups
#
# One security group for the SRE ALB:
# - Ingress HTTPS (443) from VPC CIDR (internal) or allowed_source_cidrs (public; must be non-empty)
# - Egress to node SG on unique container ports derived from local.services
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


# Egress: HTTPS to OIDC identity provider (required for ALB authenticate-oidc token exchange)
#
# Destination: 0.0.0.0/0 — exception acknowledged.
# The OIDC provider (var.oidc_issuer_url, default: auth.redhat.com) resolves via dynamic
# IPs on Red Hat's CDN/load balancing infrastructure. No stable CIDR block or AWS managed
# prefix list is published for this endpoint, so destination restriction is not possible.
#
# Compensating controls:
#   - Rule only exists when var.oidc_enabled = true (opt-in, not default)
#   - Restricted to TCP:443 (HTTPS) only — no broad egress
#   - ALB ingress is already restricted to allowed_source_cidrs
#   - OIDC token exchange is mutually authenticated (client_id + client_secret)
resource "aws_vpc_security_group_egress_rule" "alb_to_oidc" {
  count = var.oidc_enabled ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS to OIDC IdP for token exchange (0.0.0.0/0 — dynamic IdP IPs, see comment)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Egress: one rule per unique container port derived from local.services
resource "aws_vpc_security_group_egress_rule" "alb_to_pods" {
  for_each = local.unique_sg_ports

  security_group_id            = aws_security_group.alb.id
  description                  = "Allow ALB traffic to pods on port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  referenced_security_group_id = var.node_security_group_id
}

# -----------------------------------------------------------------------------
# Node Security Group Ingress Rules
#
# Allow SRE ALB traffic to reach pods on each service port.
# For EKS Auto Mode, targets the cluster_primary_security_group_id.
# -----------------------------------------------------------------------------

# Node SG ingress: one rule per unique container port derived from local.services
resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  for_each = local.unique_sg_ports

  security_group_id            = var.node_security_group_id
  description                  = "Allow SRE ALB traffic to pods on port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  referenced_security_group_id = aws_security_group.alb.id
}
