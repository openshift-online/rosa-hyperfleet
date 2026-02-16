# =============================================================================
# AWS Secrets Manager Resources
#
# Stores MQTT certificates and database credentials for Maestro components
# These secrets are synced to Kubernetes via External Secrets Operator
# =============================================================================

# =============================================================================
# Maestro Server Secrets
# =============================================================================

# MQTT Certificate Material for Maestro Server (sensitive)
resource "aws_secretsmanager_secret" "maestro_server_cert" {
  name                    = "maestro/server-cert"
  description             = "MQTT certificate material for Maestro Server"
  recovery_window_in_days = 0 # Force immediate deletion to allow quick recreation

  tags = merge(
    local.common_tags,
    {
      Name      = "maestro-server-cert"
      Component = "maestro-server"
    }
  )
}

resource "aws_secretsmanager_secret_version" "maestro_server_cert" {
  secret_id = aws_secretsmanager_secret.maestro_server_cert.id

  secret_string = jsonencode({
    certificate = aws_iot_certificate.maestro_server.certificate_pem
    privateKey  = aws_iot_certificate.maestro_server.private_key
    caCert      = data.http.aws_iot_root_ca.response_body
  })
}

# MQTT Configuration for Maestro Server (non-sensitive)
resource "aws_secretsmanager_secret" "maestro_server_config" {
  name                    = "maestro/server-config"
  description             = "MQTT configuration for Maestro Server"
  recovery_window_in_days = 0 # Force immediate deletion to allow quick recreation

  tags = merge(
    local.common_tags,
    {
      Name      = "maestro-server-config"
      Component = "maestro-server"
    }
  )
}

resource "aws_secretsmanager_secret_version" "maestro_server_config" {
  secret_id = aws_secretsmanager_secret.maestro_server_config.id

  secret_string = jsonencode({
    config = <<-EOT
      # MQTT Broker Configuration for AWS IoT Core
      brokerHost: "${data.aws_iot_endpoint.mqtt.endpoint_address}:8883"
      username: ""
      password: ""
      # Certificate files mounted via ASCP CSI driver
      clientCertFile: /mnt/secrets-store/certificate
      clientKeyFile: /mnt/secrets-store/privateKey
      caFile: /mnt/secrets-store/ca.crt
      topics:
        # Server publishes to all consumer topics
        sourceEvents: sources/maestro/consumers/+/sourceevents
        # Server subscribes to all agent events
        agentEvents: sources/maestro/consumers/+/agentevents
    EOT
  })
}

# Database Credentials for Maestro Server
resource "aws_secretsmanager_secret" "maestro_db_credentials" {
  name                    = "maestro/db-credentials"
  description             = "PostgreSQL database credentials for Maestro Server"
  recovery_window_in_days = 0 # Force immediate deletion to allow quick recreation

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.resource_name_base}-maestro-db-credentials"
      Component = "maestro-server"
    }
  )
}

resource "aws_secretsmanager_secret_version" "maestro_db_credentials" {
  secret_id = aws_secretsmanager_secret.maestro_db_credentials.id

  secret_string = jsonencode({
    username = aws_db_instance.maestro.username
    password = random_password.db_password.result
    host     = aws_db_instance.maestro.address
    port     = tostring(aws_db_instance.maestro.port)
    database = aws_db_instance.maestro.db_name
  })
}

# =============================================================================
# Maestro Agent Secrets - MANUAL TRANSFER
# =============================================================================
#
# Agent MQTT certificates are NOT stored in regional account Secrets Manager.
# Instead, they are output as sensitive Terraform outputs for manual transfer.
#
# Process:
# 1. Regional operator runs: terraform output -json maestro_agent_certificates
# 2. Regional operator securely transfers certificate data to management cluster operator
# 3. Management cluster operator creates secret in their own Secrets Manager
# 4. Management cluster Terraform references the secret name
#
# See outputs.tf for the certificate data outputs.
#
