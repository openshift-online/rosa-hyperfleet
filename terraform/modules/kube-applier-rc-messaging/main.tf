# =============================================================================
# kube-applier-rc-messaging Module
#
# Provisions the RC-side messaging resources that deliver DynamoDB change
# events to SQS queues via EventBridge Pipes — replacing the previous
# SNS-based notification paths.
#
# Specs path  (RC → MC): Two EventBridge Pipes (one per specs table) source
#   INSERT/MODIFY events from the RC specs DynamoDB streams and deliver them
#   to the MC-side specs SQS queue. kube-applier polls this queue for
#   immediate reconciliation instead of waiting for its safety-net poll.
#
# Status path (RC → RC): 2×N EventBridge Pipes (two status tables × N
#   operator replicas) deliver status INSERT/MODIFY events to each operator
#   pod's own SQS queue. Each pod drains only its own queue, preserving the
#   no-competing-consumers design.
#
# Resource naming:
#   Status SQS queues:      ${rc_id}-hyperfleet-operator-{0..N-1} (RC account)
#   Specs Pipe IAM role:    ${mc_name}-specs-pipe
#   Status Pipe IAM role:   ${mc_name}-status-pipe
#   KMS key alias:          alias/${mc_name}-kube-applier-messaging (RC account)
#
# Incremental IAM pattern:
#   Like the existing ${mc_name}-dynamodb-access policy, this module attaches
#   a per-MC inline policy (${mc_name}-messaging-access) to the shared
#   ${rc_id}-hyperfleet-operator role. Each MC pipeline run adds its own
#   policy, so parallel per-MC state files never collide.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy         = "terraform"
      Module            = "kube-applier-rc-messaging"
      ManagementCluster = var.mc_name
    }
  )

  # Ordinal indices for the operator replica queues (0-based)
  replica_indices = range(var.operator_replica_count)

  # IAM role for the hyperfleet-operator (RC account, shared across all MCs)
  hyperfleet_operator_role_name = "${var.rc_id}-hyperfleet-operator"

  # MC specs SQS queue ARN — predictable, constructed from known values.
  # The Pipes target this cross-account queue to notify kube-applier.
  mc_specs_queue_arn = "arn:aws:sqs:${var.aws_region}:${var.mc_aws_account_id}:${var.mc_name}-specs-notifications"
}

# =============================================================================
# KMS Key — shared encryption key for RC-side messaging resources (per MC)
# =============================================================================

resource "aws_kms_key" "messaging" {
  description             = "KMS key for ${var.mc_name} kube-applier messaging (SQS) in RC account"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = 90

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowSQS"
        Effect = "Allow"
        Principal = {
          Service = "sqs.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.mc_name}-kube-applier-messaging"
  })
}

resource "aws_kms_alias" "messaging" {
  name          = "alias/${var.mc_name}-kube-applier-messaging"
  target_key_id = aws_kms_key.messaging.key_id
}

# =============================================================================
# Status SQS Queues (status path receiver — RC DynamoDB → RC SQS)
#
# One queue per hyperfleet-operator pod replica. Each pod polls only its own
# queue (named after its hostname, e.g. hyperfleet-operator-2), eliminating
# competing-consumer problems and making queue drain deterministic on scale-down.
# =============================================================================

resource "aws_sqs_queue" "status" {
  count = var.operator_replica_count

  name                       = "${var.rc_id}-hyperfleet-operator-${count.index}"
  kms_master_key_id          = aws_kms_key.messaging.id
  message_retention_seconds  = 300 # 5 minutes — notifications are ephemeral wake-up signals
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 20 # long-polling

  tags = merge(local.common_tags, {
    Name      = "${var.rc_id}-hyperfleet-operator-${count.index}"
    Direction = "status-rc-to-rc"
    Replica   = tostring(count.index)
  })
}

# Status queues are in the same account as the Pipes — no cross-account queue
# policy is required. The status Pipe role's IAM policy grants sqs:SendMessage
# via identity-based policy, which is sufficient for same-account delivery.

# =============================================================================
# IAM: extend hyperfleet-operator role with messaging permissions (per-MC)
#
# Follows the same incremental pattern as ${mc_name}-dynamodb-access: each MC
# pipeline run attaches its own named policy to the shared operator role.
# Parallel per-MC state files never collide because policy names are unique.
# =============================================================================

resource "aws_iam_role_policy" "hyperfleet_operator_messaging" {
  name = "${var.mc_name}-messaging-access"
  role = local.hyperfleet_operator_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StatusQueuesReceive"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.status[*].arn
      },
      {
        Sid    = "MessagingKMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = aws_kms_key.messaging.arn
      },
    ]
  })
}

# =============================================================================
# EventBridge Pipe IAM — Specs path (RC DynamoDB → MC SQS)
#
# The specs Pipe role reads from the RC specs DynamoDB streams and writes to
# the MC-side specs SQS queue. The cross-account SQS write is authorised by
# the queue resource policy in the MC account (AllowSpecsPipeDelivery).
# The KMS grant for encrypting messages into the MC SQS queue is in the MC
# KMS key policy (AllowSpecsPipeDelivery stanza).
# =============================================================================

resource "aws_iam_role" "specs_pipe" {
  name = "${var.mc_name}-specs-pipe"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgePipes"
      Effect = "Allow"
      Principal = {
        Service = "pipes.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.mc_name}-specs-pipe"
  })
}

resource "aws_iam_role_policy" "specs_pipe" {
  name = "${var.mc_name}-specs-pipe"
  role = aws_iam_role.specs_pipe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSpecsStreams"
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams",
        ]
        Resource = [
          var.specs_applydesires_stream_arn,
          var.specs_readdesires_stream_arn,
        ]
      },
      {
        Sid    = "WriteToMCSpecsQueue"
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = local.mc_specs_queue_arn
      },
    ]
  })
}

# =============================================================================
# EventBridge Pipes — Specs path (one pipe per specs table → MC SQS)
# =============================================================================

resource "aws_pipes_pipe" "specs_applydesires" {
  name     = "${var.mc_name}-specs-applydesires"
  role_arn = aws_iam_role.specs_pipe.arn
  source   = var.specs_applydesires_stream_arn
  target   = local.mc_specs_queue_arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10

      filter_criteria {
        filter {
          pattern = jsonencode({
            eventName = ["INSERT", "MODIFY"]
          })
        }
      }
    }
  }

  target_parameters {
    sqs_queue_parameters {
      message_body = jsonencode({
        documentID  = "<$.dynamodb.Keys.documentID.S>"
        tableSuffix = "-applydesires"
      })
    }
  }

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-specs-applydesires"
    Direction = "specs-rc-to-mc"
  })
}

resource "aws_pipes_pipe" "specs_readdesires" {
  name     = "${var.mc_name}-specs-readdesires"
  role_arn = aws_iam_role.specs_pipe.arn
  source   = var.specs_readdesires_stream_arn
  target   = local.mc_specs_queue_arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10

      filter_criteria {
        filter {
          pattern = jsonencode({
            eventName = ["INSERT", "MODIFY"]
          })
        }
      }
    }
  }

  target_parameters {
    sqs_queue_parameters {
      message_body = jsonencode({
        documentID  = "<$.dynamodb.Keys.documentID.S>"
        tableSuffix = "-readdesires"
      })
    }
  }

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-specs-readdesires"
    Direction = "specs-rc-to-mc"
  })
}

# =============================================================================
# EventBridge Pipe IAM — Status path (RC DynamoDB → RC SQS)
#
# The status Pipe role reads from the RC status DynamoDB streams and writes to
# the RC-side operator status SQS queues. All resources are in the same account
# so no cross-account resource policies are needed on the queues.
# =============================================================================

resource "aws_iam_role" "status_pipe" {
  name = "${var.mc_name}-status-pipe"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgePipes"
      Effect = "Allow"
      Principal = {
        Service = "pipes.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.mc_name}-status-pipe"
  })
}

resource "aws_iam_role_policy" "status_pipe" {
  name = "${var.mc_name}-status-pipe"
  role = aws_iam_role.status_pipe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadStatusStreams"
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams",
        ]
        Resource = [
          var.status_applydesires_stream_arn,
          var.status_readdesires_stream_arn,
        ]
      },
      {
        Sid    = "WriteToStatusQueues"
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.status[*].arn
      },
      {
        Sid    = "StatusQueueKMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = aws_kms_key.messaging.arn
      },
    ]
  })
}

# =============================================================================
# EventBridge Pipes — Status path (2×N pipes: two tables × N replicas)
#
# Each operator replica has its own SQS queue. Each status table has its own
# set of N pipes (one per replica) so every replica receives every status
# change notification for its owned document IDs.
# =============================================================================

resource "aws_pipes_pipe" "status_applydesires" {
  count    = var.operator_replica_count
  name     = "${var.mc_name}-status-applydesires-${count.index}"
  role_arn = aws_iam_role.status_pipe.arn
  source   = var.status_applydesires_stream_arn
  target   = aws_sqs_queue.status[count.index].arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10

      filter_criteria {
        filter {
          pattern = jsonencode({
            eventName = ["INSERT", "MODIFY"]
          })
        }
      }
    }
  }

  target_parameters {
    sqs_queue_parameters {
      message_body = jsonencode({
        documentID  = "<$.dynamodb.Keys.documentID.S>"
        tableSuffix = "-applydesires"
      })
    }
  }

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-status-applydesires-${count.index}"
    Direction = "status-rc-to-rc"
    Replica   = tostring(count.index)
  })
}

resource "aws_pipes_pipe" "status_readdesires" {
  count    = var.operator_replica_count
  name     = "${var.mc_name}-status-readdesires-${count.index}"
  role_arn = aws_iam_role.status_pipe.arn
  source   = var.status_readdesires_stream_arn
  target   = aws_sqs_queue.status[count.index].arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10

      filter_criteria {
        filter {
          pattern = jsonencode({
            eventName = ["INSERT", "MODIFY"]
          })
        }
      }
    }
  }

  target_parameters {
    sqs_queue_parameters {
      message_body = jsonencode({
        documentID  = "<$.dynamodb.Keys.documentID.S>"
        tableSuffix = "-readdesires"
      })
    }
  }

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-status-readdesires-${count.index}"
    Direction = "status-rc-to-rc"
    Replica   = tostring(count.index)
  })
}
