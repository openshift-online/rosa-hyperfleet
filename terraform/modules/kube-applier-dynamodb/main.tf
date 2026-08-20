# =============================================================================
# kube-applier-dynamodb Module
#
# Creates the four DynamoDB tables used by kube-applier-aws for one Management
# Cluster. These tables live in the Regional Cluster (RC) account and are
# provisioned inline from regional-cluster/main.tf.
#
# Table naming follows the kube-applier-aws convention:
#   Prefix (--specs-table):  mc-{mc}-specs
#   Prefix (--status-table): mc-{mc}-status
#   Suffixes appended by the client: -applydesires, -readdesires
#
# All four tables carry the updateTime-index GSI used by hyperfleet-dynamo's
# two-speed polling watcher (fast GSI fan-out + full relist). DynamoDB Streams
# have been removed entirely.
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy         = "terraform"
      Module            = "kube-applier-dynamodb"
      ManagementCluster = var.mc_name
    }
  )

  # The four table names for this MC
  specs_tables = toset([
    "${var.mc_name}-specs-applydesires",
    "${var.mc_name}-specs-readdesires",
  ])

  status_tables = toset([
    "${var.mc_name}-status-applydesires",
    "${var.mc_name}-status-readdesires",
  ])

  # IAM role ARN for the kube-applier pod running in the MC account
  mc_kube_applier_role_arn = "arn:aws:iam::${var.mc_aws_account_id}:role/${var.mc_name}-kube-applier"
}

# =============================================================================
# Specs Tables (read-only for the agent, with updateTime-index GSI)
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

  attribute {
    name = "shard"
    type = "S"
  }

  attribute {
    name = "updateTime"
    type = "S"
  }

  global_secondary_index {
    name            = "updateTime-index"
    hash_key        = "shard"
    range_key       = "updateTime"
    projection_type = "ALL"
  }

  stream_enabled = false

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
# Status Tables (read-write for the agent, with updateTime-index GSI)
#
# All status tables have the updateTime-index GSI so the hyperfleet-operator
# can watch for status changes written by kube-applier-aws via the same
# two-speed GSI polling watcher used for specs tables.
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

  attribute {
    name = "shard"
    type = "S"
  }

  attribute {
    name = "updateTime"
    type = "S"
  }

  global_secondary_index {
    name            = "updateTime-index"
    hash_key        = "shard"
    range_key       = "updateTime"
    projection_type = "ALL"
  }

  stream_enabled = false

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
      Action = [
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:BatchGetItem",
        "dynamodb:Scan",
        "dynamodb:Query",
      ]
      Resource = [
        aws_dynamodb_table.specs[each.key].arn,
        "${aws_dynamodb_table.specs[each.key].arn}/index/*",
      ]
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
        "dynamodb:BatchGetItem",
        "dynamodb:Scan",
        "dynamodb:Query",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
      ]
      Resource = [
        aws_dynamodb_table.status[each.key].arn,
        "${aws_dynamodb_table.status[each.key].arn}/index/*",
      ]
    }]
  })
}
