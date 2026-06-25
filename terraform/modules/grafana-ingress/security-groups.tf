resource "aws_security_group" "alb" {
  name        = "${var.regional_id}-grafana-alb"
  description = "Security group for internet-facing Grafana ALB"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = false

  tags = {
    Name = "${var.regional_id}-grafana-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS from internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from internet (redirected to HTTPS)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_targets" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to Grafana pods"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow Grafana ALB traffic to Grafana pods"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = aws_security_group.alb.id
}
