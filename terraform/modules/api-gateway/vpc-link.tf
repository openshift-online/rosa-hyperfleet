# =============================================================================
# VPC Link v2
#
# Connects API Gateway to the internal ALB within the VPC.
# Uses API Gateway v2 VPC Link (not v1) for ALB support.
# =============================================================================

resource "aws_apigatewayv2_vpc_link" "main" {
  name               = "${var.regional_id}-api"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = var.private_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api"
  })
}
