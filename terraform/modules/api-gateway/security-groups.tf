# =============================================================================
# Security Groups
#
# Two security groups control traffic flow:
# 1. VPC Link SG - Attached to the VPC Link, allows outbound to ALB
# 2. ALB SG - Attached to the ALB, allows inbound from VPC Link and outbound to targets
# =============================================================================

# -----------------------------------------------------------------------------
# VPC Link Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name        = "${var.regional_id}-api-vpc-link"
  description = "Security group for API Gateway VPC Link"
  vpc_id      = var.vpc_id

  # Prevent Terraform from trying to detach VPC Link-managed ENIs
  revoke_rules_on_delete = false

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api-vpc-link"
  })
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  description                  = "Allow traffic to ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

# -----------------------------------------------------------------------------
# ALB Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.regional_id}-api-alb"
  description = "Security group for internal API ALB"
  vpc_id      = var.vpc_id

  # Prevent Terraform from trying to detach ALB-managed ENIs
  revoke_rules_on_delete = false

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api-alb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic from VPC Link"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.vpc_link.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_targets" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to target pods"
  ip_protocol                  = "tcp"
  from_port                    = var.target_port
  to_port                      = var.target_port
  referenced_security_group_id = var.node_security_group_id
}


# -----------------------------------------------------------------------------
# Node Security Group Ingress Rule
#
# Allow ALB to send health checks and traffic to pods in the cluster.
# For EKS Auto Mode, this must be added to the cluster_primary_security_group_id
# (not the cluster_security_group_id) because that's what nodes/pods actually use.
# -----------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow ALB health checks and traffic to pods"
  ip_protocol                  = "tcp"
  from_port                    = var.target_port
  to_port                      = var.target_port
  referenced_security_group_id = aws_security_group.alb.id
}

