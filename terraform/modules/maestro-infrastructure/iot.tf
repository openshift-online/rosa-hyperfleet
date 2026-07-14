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
          "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:client/maestro-*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Publish"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/sourceevents",
          "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/agentevents"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Subscribe"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topicfilter/sources/${var.regional_id}/consumers/*/agentevents"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Receive"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/agentevents"
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

# -----------------------------------------------------------------------------
# FedRAMP AU-09: KMS Key for IoT Core CloudWatch Log Encryption
# -----------------------------------------------------------------------------

resource "aws_kms_key" "iot_logs" {
  description             = "KMS key for IoT Core CloudWatch log encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:AWSIotLogsV2"
          }
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-iot-core-logs"
      Component = "maestro-iot"
    }
  )
}

resource "aws_kms_alias" "iot_logs" {
  name          = "alias/${var.regional_id}-iot-core-logs"
  target_key_id = aws_kms_key.iot_logs.key_id
}

resource "aws_cloudwatch_log_group" "iot_core" {
  name              = "AWSIotLogsV2"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.iot_logs.arn

  tags = merge(local.common_tags, {
    Name      = "${var.regional_id}-iot-core-logs"
    Component = "maestro-iot"
  })
}

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

      # Retry loop: IAM propagation can take 15-30s after role creation,
      # causing set-v2-logging-options to fail with InvalidRequestException.
      for attempt in $(seq 1 6); do
        if aws iot set-v2-logging-options \
          --role-arn "$${ROLE_ARN}" \
          --default-log-level "$${LOG_LEVEL}"; then
          break
        fi
        if [ "$attempt" -eq 6 ]; then
          echo "ERROR: set-v2-logging-options failed after $attempt attempts"
          exit 1
        fi
        echo "Attempt $attempt failed (IAM propagation delay), retrying in 10s..."
        sleep 10
      done
    EOT
  }

  depends_on = [aws_cloudwatch_log_group.iot_core]
}

