# =============================================================================
# API Gateway Resource Policy
#
# Restricts execute-api:Invoke to principals within this AWS Organization.
# The Platform API backend enforces its own fine-grained authorization on top
# of this perimeter control.
# =============================================================================

data "aws_organizations_organization" "current" {}

resource "aws_api_gateway_rest_api_policy" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowOrgPrincipals"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "execute-api:Invoke"
        Resource = "arn:aws:execute-api:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.main.id}/*"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = data.aws_organizations_organization.current.id
          }
        }
      }
    ]
  })
}
