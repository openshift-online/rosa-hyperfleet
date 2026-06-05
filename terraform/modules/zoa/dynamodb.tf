# =============================================================================
# DynamoDB Table for ZOA Executions
# =============================================================================
# Stores Trusted Action execution metadata and status
# PK: executionId
# GSI: account-index (accountId + createdAt) for listing by account

resource "aws_dynamodb_table" "executions" {
  name                        = local.table_name
  billing_mode                = var.billing_mode
  hash_key                    = "executionId"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "executionId"
    type = "S"
  }

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  global_secondary_index {
    name            = "account-index"
    hash_key        = "accountId"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_name
      Component = "zoa"
    }
  )
}
