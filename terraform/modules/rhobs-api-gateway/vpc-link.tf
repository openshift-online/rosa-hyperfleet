# =============================================================================
# VPC Link v2 for RHOBS API Gateway
#
# Dedicated VPC Link connecting the RHOBS REST API to the RHOBS ALB.
# Separate from the Platform API VPC Link for full network isolation.
# =============================================================================

resource "aws_apigatewayv2_vpc_link" "rhobs" {
  name               = "${var.regional_id}-rhobs"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = var.private_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-rhobs"
  })
}
