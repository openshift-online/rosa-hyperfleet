# =============================================================================
# RHOBS API Gateway Resource Policy
#
# Thanos (metrics):
# - POST /api/v1/receive: Any org account (MC remote-write)
# - GET /api/v1/query, /api/v1/query_range, /api/v1/rules: RC account only (E2E tests, internal tooling)
#
# Loki (logs):
# - POST /loki/api/v1/push: Any org account (MC log forwarding)
# - GET /loki/api/v1/query, /loki/api/v1/query_range: RC account only (E2E tests, internal tooling)
# =============================================================================

data "aws_organizations_organization" "current" {}

resource "aws_api_gateway_rest_api_policy" "rhobs" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowOrgMetricsIngestion"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "execute-api:Invoke"
        Resource = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/POST/api/v1/receive"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = data.aws_organizations_organization.current.id
          }
        }
      },
      {
        Sid    = "AllowOrgLogsIngestion"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "execute-api:Invoke"
        Resource = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/POST/loki/api/v1/push"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = data.aws_organizations_organization.current.id
          }
        }
      },
      {
        Sid    = "AllowRCAccountQuery"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = "execute-api:Invoke"
        Resource = [
          "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/GET/api/v1/query",
          "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/GET/api/v1/query_range",
          "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/GET/api/v1/rules",
          "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/GET/loki/api/v1/query",
          "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/GET/loki/api/v1/query_range"
        ]
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}
