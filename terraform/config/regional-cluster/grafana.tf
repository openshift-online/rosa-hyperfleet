# =============================================================================
# Grafana IAM Role – CloudWatch Read Access
#
# Grants the in-cluster Grafana pod read-only access to CloudWatch so the
# AWS External Services dashboard can query API Gateway, RDS, IoT Core, and
# NAT Gateway metrics directly — no exporter or scrape pipeline required.
#
# Bound to the "grafana" service account in the "grafana" namespace via
# EKS Pod Identity (matches serviceAccount.name in grafana/values.yaml).
# =============================================================================

resource "aws_iam_role" "grafana" {
  name = "${var.regional_id}-grafana"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = {
    Name = "${var.regional_id}-grafana"
  }
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name = "cloudwatch-read"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
      {
        # Required by the Grafana CloudWatch datasource to populate
        # dimension-value variables (e.g. list of DBInstanceIdentifier values).
        Sid    = "ResourceTagging"
        Effect = "Allow"
        Action = [
          "tag:GetResources"
        ]
        Resource = "*"
      },
      {
        # Required by the Grafana CloudWatch datasource to enumerate available
        # regions in the datasource UI and resolve "default" region in queries.
        Sid    = "RegionDiscovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeRegions"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "grafana" {
  cluster_name    = module.regional_cluster.cluster_name
  namespace       = "grafana"
  service_account = "grafana"
  role_arn        = aws_iam_role.grafana.arn

  tags = {
    Name = "${var.regional_id}-grafana"
  }
}

output "grafana_cloudwatch_role_arn" {
  description = "IAM role ARN granting Grafana read-only CloudWatch access (Pod Identity)"
  value       = aws_iam_role.grafana.arn
}
