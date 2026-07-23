provider "aws" {
  region = var.region
  # FedRAMP SC-13 / IA-07: Use FIPS 140-2 validated endpoints when available.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
      environment   = var.environment
    }
  }
}

data "aws_caller_identity" "current" {}

# =============================================================================
# kube-applier DynamoDB Tables
#
# Creates the six DynamoDB tables used by kube-applier-aws for this Management
# Cluster. Tables live in the RC account; the MC pipeline provisions them here
# so each MC's lifecycle is self-contained.
# =============================================================================

module "kube_applier_dynamodb" {
  source = "../../modules/kube-applier-dynamodb"

  mc_name           = var.mc_name
  mc_aws_account_id = var.mc_aws_account_id
  rc_id             = var.rc_id
  aws_region        = var.region
  enable_pitr       = var.enable_pitr
}

# =============================================================================
# Hyperfleet-Operator DynamoDB Access (per-MC scoped policy)
#
# Grants the hyperfleet-operator role access to this MC's DynamoDB tables.
# Each MC pipeline attaches its own policy, replacing the previous monolithic
# policy that enumerated all MCs from the RC config.
# =============================================================================

resource "aws_iam_role_policy" "hyperfleet_operator_dynamodb" {
  name = "${var.mc_name}-dynamodb-access"
  role = "${var.rc_id}-hyperfleet-operator"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBWriteSpecs"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.mc_name}-specs-*"
      },
      {
        Sid    = "DynamoDBReadStatus"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.mc_name}-status-*"
      },
      {
        Sid    = "DynamoDBStatusStreams"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:ListStreams",
          "dynamodbstreams:DescribeStream",
          "dynamodbstreams:GetRecords",
          "dynamodbstreams:GetShardIterator",
          "dynamodbstreams:ListStreams"
        ]
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.mc_name}-status-*/stream/*"
      }
    ]
  })
}

# =============================================================================
# kube-applier RC-side Messaging (SNS/SQS cross-account notifications)
#
# Creates the specs SNS topic in the RC account (the operator publishes here
# after writing a desire document) and the per-replica status SQS queues
# (the operator polls its own queue for status notifications from kube-applier).
#
# Also creates the cross-account SNS→SQS subscriptions for both directions:
#   Specs:  RC specs SNS topic  → MC specs SQS queue (mc_specs_queue_arn)
#   Status: MC status SNS topic → each RC operator SQS queue
#
# mc_status_sns_topic_arn and mc_specs_queue_arn are read from the MC
# management-cluster terraform state by the buildspec script. When empty
# (e.g. during the initial bootstrap run before MC messaging is provisioned)
# the module is skipped.
# =============================================================================

module "kube_applier_rc_messaging" {
  count  = var.mc_status_sns_topic_arn != "" && var.mc_specs_queue_arn != "" ? 1 : 0
  source = "../../modules/kube-applier-rc-messaging"

  mc_name                 = var.mc_name
  mc_aws_account_id       = var.mc_aws_account_id
  rc_id                   = var.rc_id
  aws_region              = var.region
  operator_replica_count  = var.operator_replica_count
  mc_status_sns_topic_arn = var.mc_status_sns_topic_arn
  mc_specs_queue_arn      = var.mc_specs_queue_arn
}
