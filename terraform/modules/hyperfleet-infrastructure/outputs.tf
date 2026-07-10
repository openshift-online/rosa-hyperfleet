# =============================================================================
# HyperFleet Infrastructure Module - Outputs
#
# These outputs are used by Helm values and ArgoCD applications to configure
# HyperFleet components
# =============================================================================

# =============================================================================
# RDS Database Outputs
# =============================================================================

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (hostname:port)"
  value       = aws_db_instance.hyperfleet.endpoint
}

output "rds_address" {
  description = "RDS PostgreSQL hostname"
  value       = aws_db_instance.hyperfleet.address
}

output "rds_port" {
  description = "RDS PostgreSQL port"
  value       = aws_db_instance.hyperfleet.port
}

output "rds_database_name" {
  description = "Name of the PostgreSQL database"
  value       = aws_db_instance.hyperfleet.db_name
}

output "rds_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.hyperfleet.id
}

# =============================================================================
# Amazon MQ Outputs
# =============================================================================

output "mq_broker_id" {
  description = "Amazon MQ broker ID"
  value       = aws_mq_broker.hyperfleet.id
}

output "mq_broker_arn" {
  description = "Amazon MQ broker ARN"
  value       = aws_mq_broker.hyperfleet.arn
}

output "mq_amqp_endpoint" {
  description = "Amazon MQ AMQPS endpoint"
  value       = aws_mq_broker.hyperfleet.instances[0].endpoints[0]
}

output "mq_console_url" {
  description = "RabbitMQ management console URL"
  value       = aws_mq_broker.hyperfleet.instances[0].console_url
}

# =============================================================================
# Secrets Manager Outputs
# =============================================================================

output "db_secret_arn" {
  description = "ARN of Secrets Manager secret containing database credentials"
  value       = aws_secretsmanager_secret.hyperfleet_db_credentials.arn
}

output "db_secret_name" {
  description = "Name of Secrets Manager secret containing database credentials"
  value       = aws_secretsmanager_secret.hyperfleet_db_credentials.name
}

output "mq_secret_arn" {
  description = "ARN of Secrets Manager secret containing MQ credentials"
  value       = aws_secretsmanager_secret.hyperfleet_mq_credentials.arn
}

output "mq_secret_name" {
  description = "Name of Secrets Manager secret containing MQ credentials"
  value       = aws_secretsmanager_secret.hyperfleet_mq_credentials.name
}

# =============================================================================
# IAM Role Outputs
# =============================================================================

output "api_role_arn" {
  description = "ARN of IAM role for HyperFleet API (Pod Identity)"
  value       = aws_iam_role.hyperfleet_api.arn
}

output "api_role_name" {
  description = "Name of IAM role for HyperFleet API"
  value       = aws_iam_role.hyperfleet_api.name
}

output "sentinel_role_arn" {
  description = "ARN of IAM role for HyperFleet Sentinel (Pod Identity)"
  value       = aws_iam_role.hyperfleet_sentinel.arn
}

output "sentinel_role_name" {
  description = "Name of IAM role for HyperFleet Sentinel"
  value       = aws_iam_role.hyperfleet_sentinel.name
}

output "adapter_role_arn" {
  description = "ARN of IAM role for HyperFleet Adapter (Pod Identity)"
  value       = aws_iam_role.hyperfleet_adapter.arn
}

output "adapter_role_name" {
  description = "Name of IAM role for HyperFleet Adapter"
  value       = aws_iam_role.hyperfleet_adapter.name
}

# =============================================================================
# ElastiCache Valkey Outputs
# =============================================================================

output "redis_endpoint" {
  description = "ElastiCache Valkey endpoint for rate limiting"
  value       = var.enable_rate_limit_redis ? aws_elasticache_replication_group.hyperfleet[0].primary_endpoint_address : null
}

output "redis_port" {
  description = "ElastiCache Valkey port"
  value       = var.enable_rate_limit_redis ? aws_elasticache_replication_group.hyperfleet[0].port : null
}

# =============================================================================
# Configuration Summary (for easy reference)
# =============================================================================

output "configuration_summary" {
  description = "Summary of HyperFleet infrastructure configuration for Helm values"
  sensitive   = true
  value = {
    database = {
      host = aws_db_instance.hyperfleet.address
      port = aws_db_instance.hyperfleet.port
      name = aws_db_instance.hyperfleet.db_name
    }
    messageQueue = {
      amqpEndpoint = aws_mq_broker.hyperfleet.instances[0].endpoints[0]
      consoleUrl   = aws_mq_broker.hyperfleet.instances[0].console_url
    }
    secrets = {
      dbSecretName = aws_secretsmanager_secret.hyperfleet_db_credentials.name
      mqSecretName = aws_secretsmanager_secret.hyperfleet_mq_credentials.name
    }
    roles = {
      apiRoleArn      = aws_iam_role.hyperfleet_api.arn
      sentinelRoleArn = aws_iam_role.hyperfleet_sentinel.arn
      adapterRoleArn  = aws_iam_role.hyperfleet_adapter.arn
    }
    redis = {
      enabled  = var.enable_rate_limit_redis
      endpoint = var.enable_rate_limit_redis ? aws_elasticache_replication_group.hyperfleet[0].primary_endpoint_address : null
      port     = var.enable_rate_limit_redis ? aws_elasticache_replication_group.hyperfleet[0].port : null
    }
  }
}
