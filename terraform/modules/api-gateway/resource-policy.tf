# =============================================================================
# API Gateway Resource Policy
#
# Allows any authenticated AWS principal to invoke the API. The Platform API
# backend handles its own authorization, so the gateway does not restrict
# by caller account.
# =============================================================================

resource "aws_api_gateway_rest_api_policy" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAllAWSAccounts"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "execute-api:Invoke"
        Resource = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.main.id}/*"
      }
    ]
  })
}
