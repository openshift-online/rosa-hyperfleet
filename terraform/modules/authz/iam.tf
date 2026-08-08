# =============================================================================
# IAM Roles for ROSA Authorization Service
#
# Creates IAM roles for use with EKS Pod Identity:
# - Frontend API: Access to DynamoDB tables and Amazon Verified Permissions
# =============================================================================

# =============================================================================
# Frontend API IAM Role
# =============================================================================

resource "aws_iam_role" "frontend_api" {
  name        = "${var.regional_id}-authz-platform-api"
  description = "IAM role for ROSA Frontend API with access to DynamoDB and AVP"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-authz-platform-api-role"
      Component = "authz"
    }
  )
}

# =============================================================================
# DynamoDB Access Policy
# =============================================================================

resource "aws_iam_role_policy" "frontend_api_dynamodb" {
  name = "${var.regional_id}-authz-dynamodb-policy"
  role = aws_iam_role.frontend_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBTableAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.accounts.arn,
          aws_dynamodb_table.admins.arn,
          aws_dynamodb_table.groups.arn,
          aws_dynamodb_table.members.arn,
          aws_dynamodb_table.policies.arn,
          aws_dynamodb_table.attachments.arn
        ]
      },
      {
        Sid    = "DynamoDBGSIAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          "${aws_dynamodb_table.members.arn}/index/*",
          "${aws_dynamodb_table.attachments.arn}/index/*"
        ]
      }
    ]
  })
}

# =============================================================================
# Amazon Verified Permissions (AVP) Access Policy
# =============================================================================

resource "aws_iam_role_policy" "frontend_api_avp" {
  name = "${var.regional_id}-authz-avp-policy"
  role = aws_iam_role.frontend_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AVPPolicyStoreManagement"
        Effect = "Allow"
        Action = [
          "verifiedpermissions:CreatePolicyStore",
          "verifiedpermissions:DeletePolicyStore",
          "verifiedpermissions:GetPolicyStore",
          "verifiedpermissions:ListPolicyStores",
          "verifiedpermissions:UpdatePolicyStore",
          "verifiedpermissions:PutSchema",
          "verifiedpermissions:GetSchema"
        ]
        Resource = "*"
      },
      {
        Sid    = "AVPPolicyManagement"
        Effect = "Allow"
        Action = [
          "verifiedpermissions:CreatePolicy",
          "verifiedpermissions:DeletePolicy",
          "verifiedpermissions:GetPolicy",
          "verifiedpermissions:ListPolicies",
          "verifiedpermissions:UpdatePolicy",
          "verifiedpermissions:CreatePolicyTemplate",
          "verifiedpermissions:DeletePolicyTemplate",
          "verifiedpermissions:GetPolicyTemplate",
          "verifiedpermissions:ListPolicyTemplates",
          "verifiedpermissions:UpdatePolicyTemplate"
        ]
        Resource = "*"
      },
      {
        Sid    = "AVPAuthorization"
        Effect = "Allow"
        Action = [
          "verifiedpermissions:IsAuthorized",
          "verifiedpermissions:IsAuthorizedWithToken"
        ]
        Resource = "*"
      }
    ]
  })
}

# =============================================================================
# Pod Identity Association
# =============================================================================

resource "aws_eks_pod_identity_association" "frontend_api" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.frontend_api_namespace
  service_account = var.frontend_api_service_account
  role_arn        = aws_iam_role.frontend_api.arn

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-authz-platform-api-pod-identity"
      Component = "authz"
    }
  )
}
