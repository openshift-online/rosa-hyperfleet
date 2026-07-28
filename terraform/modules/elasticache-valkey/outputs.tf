# =============================================================================
# ElastiCache Valkey Module Outputs
# =============================================================================

output "endpoint" {
  description = "ElastiCache Valkey primary endpoint address"
  value       = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "port" {
  description = "ElastiCache Valkey port"
  value       = aws_elasticache_replication_group.valkey.port
}
