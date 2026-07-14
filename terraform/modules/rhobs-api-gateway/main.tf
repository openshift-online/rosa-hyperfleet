# =============================================================================
# RHOBS API Gateway
#
# Dedicated REST API for RHOBS (observability) traffic. Includes its own ALB,
# VPC Link, and security groups — fully isolated from the Platform API Gateway.
# Only MC accounts can invoke this API via resource policy.
#
# Thanos (metrics):
#   POST /api/v1/receive -> VPC Link -> RHOBS ALB -> Thanos Receive (:19291)
#   GET  /api/v1/query   -> VPC Link -> RHOBS ALB -> Thanos Query Frontend (:9090)
#   GET  /api/v1/rules   -> VPC Link -> RHOBS ALB -> Thanos Query Frontend (:9090)
#
# Loki (logs):
#   POST /loki/api/v1/push        -> VPC Link -> RHOBS ALB -> Loki Distributor (:3100)
#   GET  /loki/api/v1/query       -> VPC Link -> RHOBS ALB -> Loki Query Frontend (:3100)
#   GET  /loki/api/v1/query_range -> VPC Link -> RHOBS ALB -> Loki Query Frontend (:3100)
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# REST API
# -----------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "rhobs" {
  name        = "${var.regional_id}-rhobs"
  description = "RHOBS observability API (Thanos metrics + Loki logs)"

  # Binary media types — API GW passes these payloads through as-is
  # without text encoding. Required for Prometheus remote_write and Loki push (protobuf).
  binary_media_types = ["application/x-protobuf"]

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "${var.regional_id}-rhobs"
  }
}

# -----------------------------------------------------------------------------
# Resource chain: /api -> /api/v1 -> /api/v1/receive
#                                  -> /api/v1/query
#                                  -> /api/v1/query_range
#                                  -> /api/v1/rules
# -----------------------------------------------------------------------------

resource "aws_api_gateway_resource" "api" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_rest_api.rhobs.root_resource_id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "api_v1" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "api_v1_receive" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "receive"
}

resource "aws_api_gateway_resource" "api_v1_query" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "query"
}

resource "aws_api_gateway_resource" "api_v1_query_range" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "query_range"
}

resource "aws_api_gateway_resource" "api_v1_rules" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "rules"
}

# -----------------------------------------------------------------------------
# Resource chain: /loki -> /loki/api -> /loki/api/v1 -> /loki/api/v1/push
#                                                     -> /loki/api/v1/query
#                                                     -> /loki/api/v1/query_range
# -----------------------------------------------------------------------------

resource "aws_api_gateway_resource" "loki" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_rest_api.rhobs.root_resource_id
  path_part   = "loki"
}

resource "aws_api_gateway_resource" "loki_api" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.loki.id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "loki_api_v1" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.loki_api.id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "loki_api_v1_push" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.loki_api_v1.id
  path_part   = "push"
}

resource "aws_api_gateway_resource" "loki_api_v1_query" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.loki_api_v1.id
  path_part   = "query"
}

resource "aws_api_gateway_resource" "loki_api_v1_query_range" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.loki_api_v1.id
  path_part   = "query_range"
}

# -----------------------------------------------------------------------------
# Deployment and Stage
# -----------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "rhobs" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id

  depends_on = [
    aws_api_gateway_integration.thanos_receive,
    aws_api_gateway_integration.thanos_query,
    aws_api_gateway_integration.thanos_query_range,
    aws_api_gateway_integration.thanos_rules,
    aws_api_gateway_integration.loki_push,
    aws_api_gateway_integration.loki_query,
    aws_api_gateway_integration.loki_query_range,
    aws_api_gateway_rest_api_policy.rhobs,
  ]

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.api_v1_receive.id,
      aws_api_gateway_method.thanos_receive.id,
      aws_api_gateway_integration.thanos_receive.id,
      aws_api_gateway_rest_api.rhobs.binary_media_types,
      aws_api_gateway_rest_api_policy.rhobs.policy,
      aws_api_gateway_resource.api_v1_query.id,
      aws_api_gateway_method.thanos_query.id,
      aws_api_gateway_integration.thanos_query.id,
      aws_api_gateway_resource.api_v1_query_range.id,
      aws_api_gateway_method.thanos_query_range.id,
      aws_api_gateway_integration.thanos_query_range.id,
      aws_api_gateway_resource.api_v1_rules.id,
      aws_api_gateway_method.thanos_rules.id,
      aws_api_gateway_integration.thanos_rules.id,
      aws_api_gateway_resource.loki_api_v1_push.id,
      aws_api_gateway_method.loki_push.id,
      aws_api_gateway_integration.loki_push.id,
      aws_api_gateway_resource.loki_api_v1_query.id,
      aws_api_gateway_method.loki_query.id,
      aws_api_gateway_integration.loki_query.id,
      aws_api_gateway_resource.loki_api_v1_query_range.id,
      aws_api_gateway_method.loki_query_range.id,
      aws_api_gateway_integration.loki_query_range.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# FedRAMP AU-09: KMS Key for RHOBS API Gateway Access Log Encryption
# -----------------------------------------------------------------------------

resource "aws_kms_key" "api_gateway_logs" {
  description             = "KMS key for RHOBS API Gateway CloudWatch log encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/api-gateway/${var.regional_id}-rhobs/*"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.regional_id}-rhobs-api-gateway-logs"
  }
}

resource "aws_kms_alias" "api_gateway_logs" {
  name          = "alias/${var.regional_id}-rhobs-api-gateway-logs"
  target_key_id = aws_kms_key.api_gateway_logs.key_id
}

# CloudWatch Log Group for RHOBS API Gateway access logs (FedRAMP AU-02)
resource "aws_cloudwatch_log_group" "api_gateway_access" {
  name              = "/aws/api-gateway/${var.regional_id}-rhobs/${var.stage_name}/access"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.api_gateway_logs.arn

  depends_on = [aws_kms_key.api_gateway_logs]

  tags = {
    Name = "${var.regional_id}-rhobs-api-access-logs"
  }
}

resource "aws_api_gateway_stage" "rhobs" {
  rest_api_id   = aws_api_gateway_rest_api.rhobs.id
  deployment_id = aws_api_gateway_deployment.rhobs.id
  stage_name    = var.stage_name

  # FedRAMP AU-02: Enable access logging to capture caller identity, request
  # path, response codes, and latency for all RHOBS API Gateway requests.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      caller             = "$context.identity.caller"
      user               = "$context.identity.user"
      userArn            = "$context.identity.userArn"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      resourcePath       = "$context.resourcePath"
      status             = "$context.status"
      protocol           = "$context.protocol"
      responseLength     = "$context.responseLength"
      errorMessage       = "$context.error.message"
      errorType          = "$context.error.responseType"
      integrationLatency = "$context.integrationLatency"
      responseLatency    = "$context.responseLatency"
    })
  }

  tags = {
    Name = "${var.regional_id}-rhobs-${var.stage_name}"
  }

  depends_on = [aws_cloudwatch_log_group.api_gateway_access]
}

# -----------------------------------------------------------------------------
# Method Settings
#
# Enable CloudWatch metrics (Count, Latency, 4XX/5XX) for the API Gateway.
# No execution logging — internal M2M traffic with known request patterns.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method_settings" "rhobs" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  stage_name  = aws_api_gateway_stage.rhobs.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = var.metrics_enabled
  }
}
