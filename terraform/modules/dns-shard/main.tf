# =============================================================================
# DNS Shard Module
#
# Creates a DNS shard zone with a random hash prefix under a parent region zone,
# and delegates to it via an NS record in the parent zone.
# =============================================================================

resource "random_string" "hash" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_route53_zone" "shard" {
  name = "${random_string.hash.result}.${var.region_dns_name}"
}

resource "aws_route53_record" "shard_ns" {
  zone_id = var.parent_zone_id
  name    = aws_route53_zone.shard.name
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.shard.name_servers
}
