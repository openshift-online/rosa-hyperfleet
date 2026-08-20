# =============================================================================
# Security Groups
#
# VPC-level security groups for EKS and AWS service access.
# These are created with the VPC so they're available early,
# before the EKS cluster itself is provisioned.
# =============================================================================

resource "aws_security_group" "eks_cluster" {
  name        = "${var.resource_name_base}-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.common_tags, { Name = "${var.resource_name_base}-cluster-sg" })
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.resource_name_base}-vpc-endpoints-sg"
  description = "Security group for VPC interface endpoints"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.common_tags, { Name = "${var.resource_name_base}-vpc-endpoints-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "Allow HTTPS from VPC CIDR for AWS service access"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "cluster_https" {
  security_group_id = aws_security_group.eks_cluster.id
  description       = "Allow VPC to communicate with API Server"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# Broad HTTPS egress is intentional: nodes must reach external registries (Quay.io, Red Hat)
# that cannot be scoped to AWS-managed prefix lists or VPC endpoints. To be restricted in a future update.
resource "aws_vpc_security_group_egress_rule" "cluster_https_registries" {
  security_group_id = aws_security_group.eks_cluster.id
  description       = "Allow HTTPS for container registries (Quay.io, Red Hat)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "cluster_vpc_internal" {
  security_group_id = aws_security_group.eks_cluster.id
  description       = "Allow all internal VPC communication"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr
}
