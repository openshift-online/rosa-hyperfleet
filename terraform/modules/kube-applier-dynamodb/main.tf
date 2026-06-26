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
    "${var.mc_name}-specs-applydesires",
    "${var.mc_name}-specs-deletedesires",
    "${var.mc_name}-specs-readdesires",
  ])

  status_tables = toset([
    "${var.mc_name}-status-applydesires",
    "${var.mc_name}-status-deletedesires",
    "${var.mc_name}-status-readdesires",
  ])

  # IAM role ARN for the kube-applier pod running in the MC account
  mc_kube_applier_role_arn = "arn:aws:iam::${var.mc_aws_account_id}:role/${var.mc_name}-kube-applier"
}

# =============================================================================
# Specs Tables (read-only for the agent, with DynamoDB Streams)
# =============================================================================

resource "aws_dynamodb_table" "specs" {
  for_each = local.specs_tables

  name         = each.key
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "documentID"

  attribute {
    name = "documentID"
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
  hash_key     = "documentID"

  attribute {
    name = "documentID"
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

# =============================================================================
# Cross-account resource-based policies
#
# DynamoDB requires a resource-based policy on the table in addition to the
# identity-based policy on the caller's role for cross-account access.
# These grant the MC kube-applier role the minimum required permissions.
# =============================================================================

resource "aws_dynamodb_resource_policy" "specs" {
  for_each     = local.specs_tables
  resource_arn = aws_dynamodb_table.specs[each.key].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowMCKubeApplierRead"
      Effect = "Allow"
      Principal = {
        AWS = local.mc_kube_applier_role_arn
      }
      # Streams actions (DescribeStream, GetRecords, GetShardIterator, ListStreams)
      # are NOT valid in DynamoDB table resource policies — they are covered by
      # the identity-based policy on the MC kube-applier role (kube-applier/iam.tf).
      Action = [
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:Query",
      ]
      Resource = aws_dynamodb_table.specs[each.key].arn
    }]
  })
}

resource "aws_dynamodb_resource_policy" "status" {
  for_each     = local.status_tables
  resource_arn = aws_dynamodb_table.status[each.key].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowMCKubeApplierReadWrite"
      Effect = "Allow"
      Principal = {
        AWS = local.mc_kube_applier_role_arn
      }
      Action = [
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:Query",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
      ]
      Resource = aws_dynamodb_table.status[each.key].arn
    }]
  })
}
