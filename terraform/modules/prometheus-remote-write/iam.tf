# =============================================================================
# Prometheus Remote Write IAM Role and Policies
# =============================================================================

# IAM role for Prometheus with Pod Identity
resource "aws_iam_role" "prometheus" {
  name        = "${var.management_id}-prometheus"
  description = "IAM role for Prometheus to invoke API Gateway for metrics remote_write"

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
      Name = "${var.management_id}-prometheus-role"
    }
  )
}

# Policy: Invoke API Gateway /api/v1/receive endpoint in the regional account
#
# Uses a wildcard for the API Gateway ID because the MC provisioning pipeline
# does not currently have access to the RC API Gateway ID at plan time.
# The RC-side API Gateway resource policy is the primary access control —
# it restricts which MC accounts can invoke the endpoint.
resource "aws_iam_role_policy" "prometheus_api_gateway" {
  name = "${var.management_id}-prometheus-api-gw"
  role = aws_iam_role.prometheus.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "execute-api:Invoke"
      Resource = "arn:aws:execute-api:${data.aws_region.current.name}:${var.regional_aws_account_id}:*/POST/api/v1/receive"
    }]
  })
}

# Pod Identity Association for sigv4-proxy
# The sigv4-proxy runs as a standalone Deployment (not a sidecar) with its own
# ServiceAccount. It signs outbound requests to the API Gateway with SigV4.
resource "aws_eks_pod_identity_association" "sigv4_proxy" {
  cluster_name    = var.eks_cluster_name
  namespace       = "monitoring"
  service_account = "sigv4-proxy"
  role_arn        = aws_iam_role.prometheus.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.management_id}-sigv4-proxy-pod-identity"
    }
  )
}
