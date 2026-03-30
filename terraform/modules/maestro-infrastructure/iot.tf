# =============================================================================
# AWS IoT Core Resources
#
# Creates certificates and policies for Maestro Server to communicate over MQTT
# on port 8883 with certificate-based authentication.
#
# Note: IoT Things are NOT created - they're only needed for Device Shadows
# and IoT Jobs, which Maestro doesn't use. MQTT only requires cert + policy.
# =============================================================================

# Get AWS IoT Core MQTT endpoint
data "aws_iot_endpoint" "mqtt" {
  endpoint_type = "iot:Data-ATS"
}

# Download AWS IoT Root CA certificate
data "http" "aws_iot_root_ca" {
  url = "https://www.amazontrust.com/repository/AmazonRootCA1.pem"
}

# =============================================================================
# Maestro Server - IoT Certificate and Policy
# =============================================================================

resource "aws_iot_certificate" "maestro_server" {
  active = true
}

# IoT Policy for Maestro Server (Publisher/Subscriber)
resource "aws_iot_policy" "maestro_server" {
  name = "${var.regional_id}-maestro-server-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["iot:Connect"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:client/maestro-*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Publish"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/sourceevents",
          # The server also needs publish on agentevents: the sdk-go MQTT source client
          # publishes a spec-resync request to agentevents when responding to agent
          # resync triggers. Removing this permission breaks server↔agent connectivity.
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/agentevents"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Subscribe"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topicfilter/sources/${var.regional_id}/consumers/*/agentevents"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Receive"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/agentevents"
        ]
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-maestro-server-policy"
      Component = "maestro-server"
    }
  )
}

resource "aws_iot_policy_attachment" "maestro_server" {
  policy = aws_iot_policy.maestro_server.name
  target = aws_iot_certificate.maestro_server.arn
}

# =============================================================================
# IoT Core Logging
#
# These are account-level singleton resources (one IAM role globally, one
# logging config per region). We use a null_resource with AWS CLI calls so
# that teardown of any individual environment does NOT remove the logging
# configuration or the shared IAM role.
# =============================================================================

resource "null_resource" "iot_logging" {
  triggers = {
    log_level = var.iot_log_level
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      ACCOUNT_ID="${data.aws_caller_identity.current.account_id}"
      ROLE_NAME="iot-logging"
      ROLE_ARN="arn:aws:iam::$${ACCOUNT_ID}:role/$${ROLE_NAME}"
      LOG_LEVEL="${var.iot_log_level}"

      # Create IAM role (idempotent — ignore "already exists" error)
      aws iam create-role \
        --role-name "$${ROLE_NAME}" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"iot.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags 'Key=Component,Value=iot-core' 'Key=Name,Value=iot-logging' \
        2>&1 || true

      # Attach logging policy (idempotent)
      aws iam attach-role-policy \
        --role-name "$${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSIoTLogging" \
        2>&1 || true

      # Brief wait for IAM propagation
      sleep 5

      # Set IoT logging options (idempotent — overwrites existing config)
      aws iot set-v2-logging-options \
        --role-arn "$${ROLE_ARN}" \
        --default-log-level "$${LOG_LEVEL}"
    EOT
  }
}

