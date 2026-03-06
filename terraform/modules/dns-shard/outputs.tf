# =============================================================================
# DNS Shard Module - Outputs
# =============================================================================

output "zone_id" {
  description = "Route53 hosted zone ID for this DNS shard"
  value       = aws_route53_zone.shard.zone_id
}

output "zone_name" {
  description = "Full DNS name of this shard (hash-prefixed)"
  value       = aws_route53_zone.shard.name
}

output "name_servers" {
  description = "Nameservers for this DNS shard zone"
  value       = aws_route53_zone.shard.name_servers
}
