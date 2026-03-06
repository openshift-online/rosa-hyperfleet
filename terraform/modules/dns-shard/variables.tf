# =============================================================================
# DNS Shard Module - Variables
# =============================================================================

variable "parent_zone_id" {
  description = "Route53 hosted zone ID of the parent region zone"
  type        = string
}

variable "region_dns_name" {
  description = "Base DNS name for the region (e.g., 'us-east-2.stage.rosa.example.com')"
  type        = string
}
