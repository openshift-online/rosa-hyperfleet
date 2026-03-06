# =============================================================================
# DNS Configuration
# =============================================================================

# Public hosted zone for the region (e.g., us-east-2.stage.rosa.example.com)
resource "aws_route53_zone" "region" {
  name = var.region_dns_name
}

# DNS shards - each gets a random hash-prefixed subdomain delegated from the region zone
module "dns_shard" {
  count  = var.dns_shard_count
  source = "../../modules/dns-shard"

  parent_zone_id  = aws_route53_zone.region.zone_id
  region_dns_name = var.region_dns_name
}
