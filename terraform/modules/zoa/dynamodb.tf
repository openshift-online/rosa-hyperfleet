# =============================================================================
# DynamoDB Table for ZOA Executions
# =============================================================================
# Stores Trusted Action execution metadata and status
# PK: executionId
# GSI: account-index (accountId + createdAt) for listing by account
# GSI: status-index (status + createdAt) for reconciler polling

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
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "account-index"
    hash_key        = "accountId"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
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

# =============================================================================
# DynamoDB Table for ZOA Audit Log
# =============================================================================
# Stores API call audit entries for compliance and observability
# PK: accountId, SK: timestamp
# TTL: 365-day automatic expiration

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
