# =============================================================================
# kube-applier-rc-messaging Module
#
# Provisions the RC-side messaging resources that deliver DynamoDB change
# events to SQS queues via EventBridge Pipes — replacing the previous
# SNS-based notification paths.
#
# Specs path  (RC → RC SQS → kube-applier cross-account): Two EventBridge
#   Pipes (one per specs table) source INSERT/MODIFY events from the RC specs
#   DynamoDB streams and deliver them to a per-MC specs SQS queue in the RC
#   account. kube-applier polls this queue cross-account using its existing
#   Pod Identity role. Cross-account pipes are not supported by EventBridge
#   Pipes, so both the pipe and its target queue live in the RC account.
#
# Status path (RC → RC SQS): 2×N EventBridge Pipes (two status tables × N
#   operator replicas) deliver status INSERT/MODIFY events to each operator
#   pod's own SQS queue. Each pod drains only its own queue, preserving the
#   no-competing-consumers design.
#
# Resource naming (all RC account):
#   Specs SQS queue:        ${mc_name}-specs-notifications
#   Status SQS queues:      ${rc_id}-hyperfleet-operator-{0..N-1}
#   Specs Pipe IAM role:    ${mc_name}-specs-pipe
#   Status Pipe IAM role:   ${mc_name}-status-pipe
#   KMS key alias:          alias/${mc_name}-kube-applier-messaging
#
# Deterministic ARN/URL pattern:
#   All queue ARNs and URLs are constructable from (mc_name, rc_id, region,
#   account_id) without cross-stack output passing, matching the pattern used
#   for DynamoDB resource policies.
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

  # IAM role for kube-applier (MC account). Deterministic — constructed from
  # known inputs so no cross-account output passing is required.
  kube_applier_role_arn = "arn:${data.aws_partition.current.partition}:iam::${var.mc_aws_account_id}:role/${var.mc_name}-kube-applier"
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
      {
        # kube-applier runs in the MC account and polls the specs queue
        # cross-account. It needs Decrypt access to read messages.
        # Use MC account root + PrincipalArn condition so this stanza is
        # valid at key-creation time even before the role exists.
        Sid    = "AllowKubeApplierDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.mc_aws_account_id}:root"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalArn" = local.kube_applier_role_arn
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
# Specs SQS Queue (specs path receiver — RC EventBridge Pipe → RC SQS)
#
# One queue per MC. kube-applier polls this queue cross-account; competing
# consumers on spec work items are fine (unlike status, which is per-replica).
# The queue lives in the RC account so the EventBridge Pipe can target it
# without cross-account restrictions.
# =============================================================================

resource "aws_sqs_queue" "specs" {
  name                       = "${var.mc_name}-specs-notifications"
  kms_master_key_id          = aws_kms_key.messaging.id
  message_retention_seconds  = 300
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 20

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-specs-notifications"
    Direction = "specs-rc-to-rc"
  })
}

# Allow the kube-applier role (MC account) to poll this queue cross-account.
# Same account-root + PrincipalArn pattern to keep the policy valid before
# the role exists.
resource "aws_sqs_queue_policy" "specs" {
  queue_url = aws_sqs_queue.specs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowKubeApplierReceive"
      Effect = "Allow"
      Principal = {
        AWS = "arn:${data.aws_partition.current.partition}:iam::${var.mc_aws_account_id}:root"
      }
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
      ]
      Resource = aws_sqs_queue.specs.arn
      Condition = {
        StringEquals = {
          "aws:PrincipalArn" = local.kube_applier_role_arn
        }
      }
    }]
  })
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
  message_retention_seconds  = 300
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 20

  tags = merge(local.common_tags, {
    Name      = "${var.rc_id}-hyperfleet-operator-${count.index}"
    Direction = "status-rc-to-rc"
    Replica   = tostring(count.index)
  })
}

# Status queues are same-account as the Pipes — no queue policy needed.
# The status Pipe role's identity-based policy grants sqs:SendMessage directly.

# =============================================================================
# IAM: extend hyperfleet-operator role with messaging permissions (per-MC)
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
# EventBridge Pipe IAM — Specs path (RC DynamoDB → RC SQS)
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
        Sid      = "WriteToSpecsQueue"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.specs.arn
      },
      {
        Sid    = "SpecsQueueKMSAccess"
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
# EventBridge Pipes — Specs path (one pipe per specs table → RC SQS)
# =============================================================================

resource "aws_pipes_pipe" "specs_applydesires" {
  name     = "${var.mc_name}-specs-applydesires"
  role_arn = aws_iam_role.specs_pipe.arn
  source   = var.specs_applydesires_stream_arn
  target   = aws_sqs_queue.specs.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10
    }

    filter_criteria {
      filter {
        pattern = jsonencode({
          eventName = ["INSERT", "MODIFY"]
        })
      }
    }
  }

  target_parameters {
    input_template = jsonencode({
      documentID  = "<$.dynamodb.Keys.documentID.S>"
      tableSuffix = "-applydesires"
    })

    sqs_queue_parameters {}
  }

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-specs-applydesires"
    Direction = "specs-rc-to-rc"
  })
}

resource "aws_pipes_pipe" "specs_readdesires" {
  name     = "${var.mc_name}-specs-readdesires"
  role_arn = aws_iam_role.specs_pipe.arn
  source   = var.specs_readdesires_stream_arn
  target   = aws_sqs_queue.specs.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10
    }

    filter_criteria {
      filter {
        pattern = jsonencode({
          eventName = ["INSERT", "MODIFY"]
        })
      }
    }
  }

  target_parameters {
    input_template = jsonencode({
      documentID  = "<$.dynamodb.Keys.documentID.S>"
      tableSuffix = "-readdesires"
    })

    sqs_queue_parameters {}
  }

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-specs-readdesires"
    Direction = "specs-rc-to-rc"
  })
}

# =============================================================================
# EventBridge Pipe IAM — Status path (RC DynamoDB → RC SQS)
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
        Sid      = "WriteToStatusQueues"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
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
    }

    filter_criteria {
      filter {
        pattern = jsonencode({
          eventName = ["INSERT", "MODIFY"]
        })
      }
    }
  }

  target_parameters {
    input_template = jsonencode({
      documentID  = "<$.dynamodb.Keys.documentID.S>"
      tableSuffix = "-applydesires"
    })

    sqs_queue_parameters {}
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
    }

    filter_criteria {
      filter {
        pattern = jsonencode({
          eventName = ["INSERT", "MODIFY"]
        })
      }
    }
  }

  target_parameters {
    input_template = jsonencode({
      documentID  = "<$.dynamodb.Keys.documentID.S>"
      tableSuffix = "-readdesires"
    })

    sqs_queue_parameters {}
  }

  tags = merge(local.common_tags, {
    Name      = "${var.mc_name}-status-readdesires-${count.index}"
    Direction = "status-rc-to-rc"
    Replica   = tostring(count.index)
  })
}
