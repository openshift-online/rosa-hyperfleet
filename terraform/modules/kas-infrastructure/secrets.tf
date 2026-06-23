# =============================================================================
# AWS Secrets Manager Resources
#
# Stores database credentials for the KAS server (Kine PostgreSQL connection).
# The secret is synced to Kubernetes via AWS Secrets and Configuration Provider
# (ASCP) using the SecretProviderClass in the kas Helm chart.
# =============================================================================

resource "aws_secretsmanager_secret" "kas_db_credentials" {
  name                    = "${var.regional_id}-kas-db-credentials"
  description             = "PostgreSQL database credentials for KAS server (Kine backend)"
  recovery_window_in_days = 0 # Force immediate deletion to allow quick recreation

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-kas-db-credentials"
      Component = "kas"
    }
  )
}

resource "aws_secretsmanager_secret_version" "kas_db_credentials" {
  secret_id = aws_secretsmanager_secret.kas_db_credentials.id

  secret_string = jsonencode({
    username = aws_db_instance.kas.username
    password = random_password.db_password.result
    host     = aws_db_instance.kas.address
    port     = tostring(aws_db_instance.kas.port)
    database = aws_db_instance.kas.db_name
  })
}
