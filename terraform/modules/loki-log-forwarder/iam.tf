# =============================================================================
# Loki Log Forwarder IAM Role and Policies
# =============================================================================

resource "aws_iam_role" "loki_forwarder" {
  name        = "${var.management_id}-loki-forwarder"
  description = "IAM role for sigv4-proxy to invoke API Gateway for Loki log push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.management_id}-loki-forwarder-role"
    }
  )
}

# Policy: Invoke API Gateway /loki/api/v1/push endpoint in the regional account
#
# Uses a wildcard for the API Gateway ID because the MC provisioning pipeline
# does not currently have access to the RC API Gateway ID at plan time.
# The RC-side API Gateway resource policy is the primary access control —
# it restricts which MC accounts can invoke the endpoint.
resource "aws_iam_role_policy" "loki_api_gateway" {
  name = "${var.management_id}-loki-api-gw"
  role = aws_iam_role.loki_forwarder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "execute-api:Invoke"
      Resource = "arn:aws:execute-api:${data.aws_region.current.name}:${var.regional_aws_account_id}:*/POST/loki/api/v1/push"
    }]
  })
}

# Pod Identity Association for sigv4-proxy-logs
# The sigv4-proxy-logs runs as a standalone Deployment with its own
# ServiceAccount. It signs outbound requests to the API Gateway with SigV4.
resource "aws_eks_pod_identity_association" "sigv4_proxy_logs" {
  cluster_name    = var.eks_cluster_name
  namespace       = "vector"
  service_account = "sigv4-proxy-logs"
  role_arn        = aws_iam_role.loki_forwarder.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.management_id}-sigv4-proxy-logs-pod-identity"
    }
  )
}
