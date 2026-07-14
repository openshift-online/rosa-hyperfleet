# =============================================================================
# Maestro Agent IAM Role and Policies
# =============================================================================

# IAM role for Maestro Agent with Pod Identity
resource "aws_iam_role" "maestro_agent" {
  name        = "${var.management_id}-maestro-agent"
  description = "IAM role for Maestro Agent with access to local Secrets Manager and regional IoT Core"

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
      Name = "${var.management_id}-maestro-agent-role"
    }
  )
}

# Policy: Read local Secrets Manager (certificate and configuration)
resource "aws_iam_role_policy" "maestro_agent_secrets" {
  name = "${var.management_id}-maestro-agent-secrets"
  role = aws_iam_role.maestro_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = [
        aws_secretsmanager_secret.maestro_agent_cert.arn,
        aws_secretsmanager_secret.maestro_agent_config.arn
      ]
    }]
  })
}

# Policy: Connect to regional IoT Core
resource "aws_iam_role_policy" "maestro_agent_iot" {
  name = "${var.management_id}-maestro-agent-iot"
  role = aws_iam_role.maestro_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "iot:Connect",
        "iot:Subscribe",
        "iot:Receive",
        "iot:Publish"
      ]
      Resource = [
        # IoT Core resources are in the REGIONAL account
        "arn:aws:iot:${data.aws_region.current.name}:${var.regional_aws_account_id}:client/*",
        "arn:aws:iot:${data.aws_region.current.name}:${var.regional_aws_account_id}:topic/${var.mqtt_topic_prefix}/${var.management_id}/*",
        "arn:aws:iot:${data.aws_region.current.name}:${var.regional_aws_account_id}:topicfilter/${var.mqtt_topic_prefix}/${var.management_id}/*"
      ]
    }]
  })
}

# Pod Identity Association
resource "aws_eks_pod_identity_association" "maestro_agent" {
  cluster_name    = var.eks_cluster_name
  namespace       = "maestro-agent"
  service_account = "maestro-agent"
  role_arn        = aws_iam_role.maestro_agent.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.management_id}-maestro-agent-pod-identity"
    }
  )
}
