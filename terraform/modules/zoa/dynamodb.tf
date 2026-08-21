# =============================================================================
# DynamoDB Table for ZOA Executions
# =============================================================================
# Stores Trusted Action execution metadata and status.
# PK: executionId (direct Get by ID)
# TTL: 365 days (DYNAMODB_TTL_DAYS env var)
#
# Operation → Index mapping:
#
#   | Operation (code path)                | Index              | Frequency          |
#   |--------------------------------------|--------------------|--------------------|
#   | Reconciler: QueryByTargetAndStatus   | target-status-index| Every 5-30s/cluster|
#   | GC: QueryTerminalByTarget            | target-status-index| Every 60s/cluster  |
#   | Concurrency limiter: CountActiveByTarget | target-status-index| Per dispatch   |
#   | Dispatch cooldown: ListByTargetAndAction  | date-bucket-index  | Per write-TA only |
#   | CLI: zoa runs [filters]              | date-bucket-index  | Human-driven       |
#   | Get by ID: Get                       | Table PK           | Per dispatch/get   |
#
# GSI Architecture (2 indexes):
#
#   target-status-index (PK=targetCluster, SK=targetStatusKey)
#     Machine-driven hot path. Runs every 5-30 seconds per cluster.
#     Composite sort key format: "{status}#{timestamp}" enables begins_with queries.
#     - Reconciler: finds dispatched/approved executions for THIS cluster only
#     - GC: finds terminal executions (succeeded/failed) older than cleanup threshold
#     - Concurrency limiter: counts active (dispatched+approved) items per target
#     Cost: O(active_items_on_target) — typically 0-5 items per query.
#
#   date-bucket-index (PK=dateBucket, SK=createdAt)
#     Human-driven + cooldown path. Latency tolerance: seconds.
#     Daily partition key (e.g. "2026-08-27") with createdAt as sort key.
#     - CLI listing: iterates daily buckets backwards until --since boundary,
#       non-key filters (target, status, action, operator) as FilterExpressions
#     - Dispatch cooldown: queries only today's bucket (SK >= 300s ago) with
#       target+action as FilterExpression. Only triggered for write TAs without
#       force=true. At 1K/day, reads ~3-4 items in a 5min window.
#     - CLI enforces --since 24h default, guaranteeing bounded queries

resource "aws_dynamodb_table" "executions" {
  name                        = local.table_name
  billing_mode                = var.billing_mode
  hash_key                    = "executionId"
  deletion_protection_enabled = var.environment != "ephemeral"

  attribute {
    name = "executionId"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  attribute {
    name = "targetCluster"
    type = "S"
  }

  attribute {
    name = "targetStatusKey"
    type = "S"
  }

  attribute {
    name = "dateBucket"
    type = "S"
  }

  global_secondary_index {
    name            = "target-status-index"
    hash_key        = "targetCluster"
    range_key       = "targetStatusKey"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "date-bucket-index"
    hash_key        = "dateBucket"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.environment != "ephemeral"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.zoa.arn
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_name
      Component = "zoa"
    }
  )
}

# Cross-account access for MC Lambda roles
resource "aws_dynamodb_resource_policy" "executions_cross_account" {
  resource_arn = aws_dynamodb_table.executions.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCrossAccountLambdaAccess"
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
        "dynamodb:DescribeTable",
      ]
      Resource = [
        aws_dynamodb_table.executions.arn,
        "${aws_dynamodb_table.executions.arn}/index/*",
      ]
      Condition = {
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
        }
        StringLike = {
          "aws:PrincipalArn" = "arn:*:iam::*:role/*-zoa-lambda"
        }
      }
    }]
  })
}

# =============================================================================
# DynamoDB Table for ZOA Audit Log
# =============================================================================
# Stores API call audit entries for compliance and observability.
# PK: accountId, SK: timestamp (per-account listing from the Lambda's own account)
# TTL: 365 days (DYNAMODB_TTL_DAYS env var)
#
# Operation → Index mapping:
#
#   | Operation (code path)               | Index             | Frequency     |
#   |-------------------------------------|-------------------|---------------|
#   | CLI: zoa audit [filters]            | date-bucket-index | Human-driven  |
#   | Record (write): Record              | Table PK          | Per API call  |
#
# GSI Architecture (1 index):
#
#   date-bucket-index (PK=dateBucket, SK=timestamp)
#     Human-driven path. Only consumer is `zoa audit` CLI command.
#     - Iterates daily buckets backwards from today until --since boundary
#     - Non-key filters (target, action, operator, method) as FilterExpressions
#     - CLI enforces --since 24h default, guaranteeing bounded queries
#     - Daily partition key (e.g. "2026-08-27") with no hot-partition risk at any scale

resource "aws_dynamodb_table" "audit_log" {
  name                        = local.audit_table_name
  billing_mode                = var.billing_mode
  hash_key                    = "accountId"
  range_key                   = "timestamp"
  deletion_protection_enabled = var.environment != "ephemeral"

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "dateBucket"
    type = "S"
  }

  global_secondary_index {
    name            = "date-bucket-index"
    hash_key        = "dateBucket"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.zoa.arn
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.environment != "ephemeral"
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.audit_table_name
      Component = "zoa"
    }
  )
}

# Cross-account access for MC Lambda roles (audit writes + cross-cluster reads)
resource "aws_dynamodb_resource_policy" "audit_cross_account" {
  resource_arn = aws_dynamodb_table.audit_log.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCrossAccountLambdaAuditAccess"
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = [
        "dynamodb:PutItem",
        "dynamodb:Query",
      ]
      Resource = [
        aws_dynamodb_table.audit_log.arn,
        "${aws_dynamodb_table.audit_log.arn}/index/*",
      ]
      Condition = {
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
        }
        StringLike = {
          "aws:PrincipalArn" = "arn:*:iam::*:role/*-zoa-lambda"
        }
      }
    }]
  })
}
