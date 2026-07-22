# =============================================================================
# HyperFleet DB Module Outputs
# =============================================================================

output "endpoint" {
  description = "Aurora cluster endpoint (host:port)"
  value       = aws_rds_cluster.hyperfleet_db.endpoint
}

output "address" {
  description = "Aurora cluster hostname"
  value       = aws_rds_cluster.hyperfleet_db.endpoint
}

output "port" {
  description = "Aurora cluster port"
  value       = aws_rds_cluster.hyperfleet_db.port
}

output "database_name" {
  description = "Database name"
  value       = aws_rds_cluster.hyperfleet_db.database_name
}

output "dsn_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the PostgreSQL DSN"
  value       = aws_secretsmanager_secret.dsn.arn
}

output "dsn_secret_name" {
  description = "Name of the Secrets Manager secret containing the PostgreSQL DSN"
  value       = aws_secretsmanager_secret.dsn.name
}

output "master_password_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the master password"
  value       = aws_secretsmanager_secret.master.arn
}

output "security_group_id" {
  description = "Security group ID for the Aurora cluster"
  value       = aws_security_group.hyperfleet_db.id
}

output "kms_key_arn" {
  description = "KMS key ARN used for Aurora encryption"
  value       = aws_kms_key.hyperfleet_db.arn
}

output "cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.hyperfleet_db.id
}
