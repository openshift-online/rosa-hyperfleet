# =============================================================================
# Security Groups
#
# Two security groups control traffic flow:
# 1. VPC Link SG - Attached to the VPC Link, allows outbound to RHOBS ALB
# 2. ALB SG - Attached to the ALB, allows inbound from VPC Link and outbound
#    to Thanos pods
# =============================================================================

# -----------------------------------------------------------------------------
# VPC Link Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name        = "${var.regional_id}-rhobs-vpc-link"
  description = "Security group for RHOBS API Gateway VPC Link"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = false

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-rhobs-vpc-link"
  })
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  description                  = "Allow traffic to RHOBS ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

# -----------------------------------------------------------------------------
# ALB Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.regional_id}-rhobs-alb"
  description = "Security group for internal RHOBS ALB"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = false

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-rhobs-alb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic from RHOBS VPC Link"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.vpc_link.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_thanos_receive" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to Thanos Receive pods"
  ip_protocol                  = "tcp"
  from_port                    = var.thanos_receive_port
  to_port                      = var.thanos_receive_port
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_thanos_health" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow ALB health checks to Thanos Receive HTTP port"
  ip_protocol                  = "tcp"
  from_port                    = var.thanos_receive_health_port
  to_port                      = var.thanos_receive_health_port
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_thanos_query" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to Thanos Query Frontend pods"
  ip_protocol                  = "tcp"
  from_port                    = var.thanos_query_port
  to_port                      = var.thanos_query_port
  referenced_security_group_id = var.node_security_group_id
}

# -----------------------------------------------------------------------------
# Node Security Group Ingress Rules
#
# Allow RHOBS ALB to send health checks and traffic to Thanos pods.
# For EKS Auto Mode, this must target the cluster_primary_security_group_id.
# -----------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_thanos" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow RHOBS ALB traffic to Thanos Receive pods"
  ip_protocol                  = "tcp"
  from_port                    = var.thanos_receive_port
  to_port                      = var.thanos_receive_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_thanos_health" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow RHOBS ALB health checks to Thanos Receive HTTP port"
  ip_protocol                  = "tcp"
  from_port                    = var.thanos_receive_health_port
  to_port                      = var.thanos_receive_health_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_thanos_query" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow RHOBS ALB traffic to Thanos Query Frontend pods"
  ip_protocol                  = "tcp"
  from_port                    = var.thanos_query_port
  to_port                      = var.thanos_query_port
  referenced_security_group_id = aws_security_group.alb.id
}

# -----------------------------------------------------------------------------
# Loki Security Group Rules
# -----------------------------------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "alb_to_loki_distributor" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to Loki Distributor pods"
  ip_protocol                  = "tcp"
  from_port                    = var.loki_distributor_port
  to_port                      = var.loki_distributor_port
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_loki_query_frontend" {
  count = var.loki_distributor_port != var.loki_query_frontend_port ? 1 : 0

  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to Loki Query Frontend pods"
  ip_protocol                  = "tcp"
  from_port                    = var.loki_query_frontend_port
  to_port                      = var.loki_query_frontend_port
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_loki_distributor" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow RHOBS ALB traffic to Loki Distributor pods"
  ip_protocol                  = "tcp"
  from_port                    = var.loki_distributor_port
  to_port                      = var.loki_distributor_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb_loki_query_frontend" {
  count = var.loki_distributor_port != var.loki_query_frontend_port ? 1 : 0

  security_group_id            = var.node_security_group_id
  description                  = "Allow RHOBS ALB traffic to Loki Query Frontend pods"
  ip_protocol                  = "tcp"
  from_port                    = var.loki_query_frontend_port
  to_port                      = var.loki_query_frontend_port
  referenced_security_group_id = aws_security_group.alb.id
}
