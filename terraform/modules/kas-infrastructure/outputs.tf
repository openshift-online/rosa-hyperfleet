# =============================================================================
# KAS Infrastructure Module - Outputs
#
# These outputs are used by Helm values and ArgoCD applications to configure
# the KAS server and its Kine PostgreSQL backend.
# =============================================================================

# =============================================================================
# RDS Database Outputs
# =============================================================================

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (hostname:port)"
  value       = aws_db_instance.kas.endpoint
}

output "rds_address" {
  description = "RDS PostgreSQL hostname"
  value       = aws_db_instance.kas.address
}

output "rds_port" {
  description = "RDS PostgreSQL port"
  value       = aws_db_instance.kas.port
}

output "rds_database_name" {
  description = "Name of the PostgreSQL database"
  value       = aws_db_instance.kas.db_name
}

output "rds_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.kas.id
}

# =============================================================================
# Secrets Manager Outputs
# =============================================================================

output "db_secret_arn" {
  description = "ARN of Secrets Manager secret containing database credentials"
  value       = aws_secretsmanager_secret.kas_db_credentials.arn
}

output "db_secret_name" {
  description = "Name of Secrets Manager secret containing database credentials"
  value       = aws_secretsmanager_secret.kas_db_credentials.name
}

# =============================================================================
# IAM Role Outputs
# =============================================================================

output "kas_role_arn" {
  description = "ARN of IAM role for KAS server (Pod Identity)"
  value       = aws_iam_role.kas_server.arn
}

output "kas_role_name" {
  description = "Name of IAM role for KAS server"
  value       = aws_iam_role.kas_server.name
}

# =============================================================================
# Configuration Summary (for easy reference)
# =============================================================================

output "configuration_summary" {
  description = "Summary of KAS infrastructure configuration for Helm values"
  sensitive   = true
  value = {
    database = {
      host = aws_db_instance.kas.address
      port = aws_db_instance.kas.port
      name = aws_db_instance.kas.db_name
    }
    secrets = {
      dbSecretName = aws_secretsmanager_secret.kas_db_credentials.name
    }
    roles = {
      kasRoleArn = aws_iam_role.kas_server.arn
    }
  }
}
