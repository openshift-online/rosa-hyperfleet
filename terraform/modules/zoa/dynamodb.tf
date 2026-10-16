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

# =============================================================================
# DynamoDB Table for ZOA Boundary Sessions
# =============================================================================
# Stores boundary session lifecycle (creating → active → terminated).
# PK: sessionId (UUID from Access session_start; not the ECS task id)
# TTL: attribute ttl, set from DYNAMODB_TTL_DAYS on write (default 365; same as executions/audit)
#
# Operation → Index mapping:
#
#   | Operation (code path)                          | Index                 | Frequency          |
#   |------------------------------------------------|-----------------------|--------------------|
#   | API: ResolveIdentity → GetByTaskID             | task-id-index         | Per boundary TA    |
#   | Worker reaper: ListExpired                     | status-deadline-index | EventBridge tick   |
#   | Worker reaper: ListActiveBeforeDeadline (idle) | status-deadline-index | EventBridge tick   |
#   | Access: GET /sessions (list/history)           | date-bucket-index     | Human-driven       |
#   | Get by session UUID: Get                         | Table PK (sessionId)  | Join/stop/exec     |
#
# GSI Architecture (3 indexes):
#
#   task-id-index (PK=taskId)
#     Identity bridge — only consumer is API Lambda attribution (pkg/api/identity.go).
#     ECS sets RoleSessionName on the boundary task role to the task UUID; that value is
#     written to taskId when the session becomes active. Each boundary zoa run does one
#     Query (Limit 1) to map task id → human operator + sessionId. No scan.
#     See rosa-hyperfleet-zoa docs/design/boundary-identity-and-storage.md
#
#   status-deadline-index (PK=status, SK=deadline)
#     Worker Lambda session reaper (pkg/scheduler/reaper.go). Two query patterns on the
#     same GSI: active items with deadline <= now (max duration), and active items with
#     deadline > now (idle candidates). EventBridge schedule per VPC — not per request.
#
#   date-bucket-index (PK=dateBucket, SK=createdAt)
#     Human-driven path. Access ListAll for zoa session list / session history — same
#     day-bucket iteration as executions/audit. scope=mine adds operator FilterExpression.
#     CLI defaults --since 24h so queries stay bounded.

resource "aws_dynamodb_table" "boundary_sessions" {
  name                        = local.sessions_table_name
  billing_mode                = var.billing_mode
  hash_key                    = "sessionId"
  deletion_protection_enabled = var.environment != "ephemeral"

  attribute {
    name = "sessionId"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "createdAt"
    type = "S"
  }
  attribute {
    name = "dateBucket"
    type = "S"
  }
  attribute {
    name = "deadline"
    type = "S"
  }
  attribute {
    name = "taskId"
    type = "S"
  }

  global_secondary_index {
    name            = "date-bucket-index"
    hash_key        = "dateBucket"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "status-deadline-index"
    hash_key        = "status"
    range_key       = "deadline"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "task-id-index"
    hash_key        = "taskId"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.environment != "ephemeral"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.zoa.arn
  }

  tags = merge(local.common_tags, { Name = local.sessions_table_name, Component = "zoa" })
}

# =============================================================================
# ZOA Boundary Targets — SSM Parameter Store
# =============================================================================
# Target registration uses SSM Parameter Store instead of DynamoDB because
# targets are static, Terraform-managed data:
#   - RC cluster: RC zoa-lambda Terraform. MC clusters: mc-zoa-target-ssm-provisioning (MC pipeline, RC state).
#   - Auto-removed on terraform destroy (no orphans, no GC)
#   - Listed via GetParametersByPath("/zoa/targets/<deployment>/")
#
# SSM parameters live in the RC account (Access Lambda reads with ambient creds;
# CLI queries through the Access API, never touches RC SSM directly).
#
# Path: /zoa/targets/<deployment_name>/<cluster_name>
# Value: {"target_type": "rc|mc", "function_url": "...", "vpc_id": "..."}
#
# The actual SSM resources are created by each cluster's Terraform module
# (zoa-lambda), not here. This comment documents the design decision.
