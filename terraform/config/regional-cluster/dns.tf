# =============================================================================
# DNS Configuration
# =============================================================================

# Public hosted zone for the region (e.g., us-east-2.stage.rosa.example.com)
resource "aws_route53_zone" "region" {
  name = var.region_dns_name
}

# Generate a random 6-character hash for the shard hosted zone
resource "random_string" "dns_shard_hash" {
  length  = 6
  special = false
  upper   = false
}

# Shard hosted zone with random hash prefix (e.g., a1b2c3.us-east-2.stage.rosa.example.com)
resource "aws_route53_zone" "shard" {
  name = "${random_string.dns_shard_hash.result}.${var.region_dns_name}"
}

# NS record in the region zone delegating to the shard zone
resource "aws_route53_record" "shard_ns" {
  zone_id = aws_route53_zone.region.zone_id
  name    = aws_route53_zone.shard.name
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.shard.name_servers
}

# Alias record pointing api.<region_dns_name> to the Platform API ALB
resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.region.zone_id
  name    = "api.${var.region_dns_name}"
  type    = "A"

  alias {
    name                   = module.api_gateway.alb_dns_name
    zone_id                = module.api_gateway.alb_zone_id
    evaluate_target_health = true
  }
}
