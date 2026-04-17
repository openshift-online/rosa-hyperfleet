# =============================================================================
# API Gateway REST API
#
# Creates a REST API with AWS_IAM authentication and a single {proxy+}
# catch-all resource that forwards all requests to the backend.
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# REST API
# -----------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.regional_id}-api"
  description = var.api_description

  # Binary media types — API GW passes these payloads through as-is
  # without text encoding. Required for Prometheus remote_write (protobuf).
  binary_media_types = ["application/x-protobuf"]

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "${var.regional_id}-api"
  }
}

# -----------------------------------------------------------------------------
# Proxy Resource: {proxy+}
#
# Catches all paths and forwards them to the backend.
# The backend service handles its own routing.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "{proxy+}"
}

# -----------------------------------------------------------------------------
# Method: ANY on {proxy+}
#
# Accepts all HTTP methods with AWS_IAM authentication.
# Requires SigV4 signed requests (use awscurl for testing).
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "AWS_IAM"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

# -----------------------------------------------------------------------------
# Root Resource Method: ANY on /
#
# Handle requests to the root path (e.g., health checks at /)
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "AWS_IAM"
}

# -----------------------------------------------------------------------------
# Deployment and Stage
# -----------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  # Ensure deployment happens after all resources are created
  depends_on = [
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration.root,
    aws_api_gateway_rest_api_policy.main,
  ]

  # Force new deployment when configuration changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy.id,
      aws_api_gateway_method.root.id,
      aws_api_gateway_integration.proxy.id,
      aws_api_gateway_integration.root.id,
      aws_api_gateway_rest_api_policy.main.policy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# API Gateway Account — CloudWatch logging role (account-level, one per region)
#
# API Gateway requires an account-level IAM role before any stage can write
# access logs to CloudWatch. Without aws_api_gateway_account, access_log_settings
# on the stage is silently ignored.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "api_gateway_cloudwatch" {
  name = "${var.regional_id}-api-gateway-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.regional_id}-api-gateway-cloudwatch"
  }
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  role       = aws_iam_role.api_gateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn

  depends_on = [aws_iam_role_policy_attachment.api_gateway_cloudwatch]
}

# CloudWatch Log Group for API Gateway access logs (FedRAMP AU-02)
resource "aws_cloudwatch_log_group" "api_gateway_access" {
  name              = "/aws/api-gateway/${var.regional_id}/${var.stage_name}/access"
  retention_in_days = 365

  tags = {
    Name = "${var.regional_id}-api-access-logs"
  }

  lifecycle {
    # NOTE: prevent_destroy breaks ephemeral environment teardown
    # prevent_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  deployment_id = aws_api_gateway_deployment.main.id
  stage_name    = var.stage_name

  # FedRAMP AU-02: Enable access logging to capture caller identity, request
  # path, response codes, and latency for all API Gateway requests.
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
    Name = "${var.regional_id}-api-${var.stage_name}"
  }

  depends_on = [
    aws_cloudwatch_log_group.api_gateway_access,
    aws_api_gateway_account.main,
  ]
}

# -----------------------------------------------------------------------------
# FedRAMP AC-08: System Use Notification
#
# Injects a DoD/FedRAMP-compliant use-notification banner into all API Gateway
# 4XX and DEFAULT responses so that unauthenticated or unauthorized callers
# receive the required warning before being granted any access.
# -----------------------------------------------------------------------------

locals {
  system_use_notification = "WARNING: This system is for authorized use only. Users (authorized or unauthorized) have no explicit or implicit expectation of privacy. Any or all uses of this system and all files on this system may be intercepted, monitored, recorded, copied, audited, inspected, and disclosed to authorized site, company, and law enforcement personnel, as well as authorized officials of other agencies. By using this system, the user consents to such interception, monitoring, recording, copying, auditing, inspection, and disclosure at the discretion of authorized site or company personnel. Unauthorized or improper use of this system may result in civil and criminal penalties and administrative or disciplinary action, as appropriate."
}

resource "aws_api_gateway_gateway_response" "unauthorized" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "UNAUTHORIZED"
  status_code   = "401"

  response_parameters = {
    "gatewayresponse.header.Warning"                   = "'${local.system_use_notification}'"
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }

  response_templates = {
    "application/json" = jsonencode({
      message               = "Unauthorized"
      systemUseNotification = local.system_use_notification
    })
  }
}

resource "aws_api_gateway_gateway_response" "access_denied" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "ACCESS_DENIED"
  status_code   = "403"

  response_parameters = {
    "gatewayresponse.header.Warning"                   = "'${local.system_use_notification}'"
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }

  response_templates = {
    "application/json" = jsonencode({
      message               = "Access Denied"
      systemUseNotification = local.system_use_notification
    })
  }
}

resource "aws_api_gateway_gateway_response" "default_4xx" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "DEFAULT_4XX"

  response_parameters = {
    "gatewayresponse.header.Warning"                   = "'${local.system_use_notification}'"
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }
}

# -----------------------------------------------------------------------------
# FedRAMP CM-07: Least Functionality — API Gateway Method Settings
#
# Restrict unnecessary capabilities: enable detailed metrics and throttling,
# disable execution logging at the method level to avoid PII in logs, and
# enforce that only necessary methods/capabilities are active.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method_settings" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = var.metrics_enabled
    logging_level          = var.logging_level
    data_trace_enabled     = var.data_trace_enabled
    throttling_burst_limit = var.throttling_burst_limit
    throttling_rate_limit  = var.throttling_rate_limit
  }
}
