# =============================================================================
# kube-applier-dynamodb Module
#
# Creates the six DynamoDB tables used by kube-applier-aws for one Management
# Cluster. These tables live in the Regional Cluster (RC) account and are
# provisioned by the Mint-DynamoDB CodePipeline stage, which assumes RC account
# credentials (analogous to the Mint-IoT stage for Maestro).
#
# Table naming follows the kube-applier-aws convention:
#   Prefix (--specs-table):  mc-{mc}-specs
#   Prefix (--status-table): mc-{mc}-status
#   Suffixes appended by the client: -applydesires, -deletedesires, -readdesires
#
# Specs tables have DynamoDB Streams enabled — the controller uses them to
# drive its SharedIndexInformer (TRIM_HORIZON shard polling).
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy          = "terraform"
      Module             = "kube-applier-dynamodb"
      ManagementCluster  = var.mc_name
    }
  )

  # The six table names for this MC
  specs_tables = toset([
    "mc-${var.mc_name}-specs-applydesires",
    "mc-${var.mc_name}-specs-deletedesires",
    "mc-${var.mc_name}-specs-readdesires",
  ])

  status_tables = toset([
    "mc-${var.mc_name}-status-applydesires",
    "mc-${var.mc_name}-status-deletedesires",
    "mc-${var.mc_name}-status-readdesires",
  ])
}

# =============================================================================
# Specs Tables (read-only for the agent, with DynamoDB Streams)
# =============================================================================

resource "aws_dynamodb_table" "specs" {
  for_each = local.specs_tables

  name         = each.key
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "DocumentID"

  attribute {
    name = "DocumentID"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  tags = merge(
    local.common_tags,
    {
      Name      = each.key
      TableType = "specs"
    }
  )
}

# =============================================================================
# Status Tables (read-write for the agent, no streams needed)
# =============================================================================

resource "aws_dynamodb_table" "status" {
  for_each = local.status_tables

  name         = each.key
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "DocumentID"

  attribute {
    name = "DocumentID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  tags = merge(
    local.common_tags,
    {
      Name      = each.key
      TableType = "status"
    }
  )
}
