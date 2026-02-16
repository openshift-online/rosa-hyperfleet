# =============================================================================
# ROSA Authorization Module - Outputs
#
# These outputs are used by Helm values and application configuration
# =============================================================================

# =============================================================================
# DynamoDB Table Outputs
# =============================================================================

output "accounts_table_name" {
  description = "Name of the accounts DynamoDB table"
  value       = aws_dynamodb_table.accounts.name
}

output "accounts_table_arn" {
  description = "ARN of the accounts DynamoDB table"
  value       = aws_dynamodb_table.accounts.arn
}

output "admins_table_name" {
  description = "Name of the admins DynamoDB table"
  value       = aws_dynamodb_table.admins.name
}

output "admins_table_arn" {
  description = "ARN of the admins DynamoDB table"
  value       = aws_dynamodb_table.admins.arn
}

output "groups_table_name" {
  description = "Name of the groups DynamoDB table"
  value       = aws_dynamodb_table.groups.name
}

output "groups_table_arn" {
  description = "ARN of the groups DynamoDB table"
  value       = aws_dynamodb_table.groups.arn
}

output "members_table_name" {
  description = "Name of the group members DynamoDB table"
  value       = aws_dynamodb_table.members.name
}

output "members_table_arn" {
  description = "ARN of the group members DynamoDB table"
  value       = aws_dynamodb_table.members.arn
}

output "policies_table_name" {
  description = "Name of the policies DynamoDB table"
  value       = aws_dynamodb_table.policies.name
}

output "policies_table_arn" {
  description = "ARN of the policies DynamoDB table"
  value       = aws_dynamodb_table.policies.arn
}

output "attachments_table_name" {
  description = "Name of the attachments DynamoDB table"
  value       = aws_dynamodb_table.attachments.name
}

output "attachments_table_arn" {
  description = "ARN of the attachments DynamoDB table"
  value       = aws_dynamodb_table.attachments.arn
}

# =============================================================================
# IAM Role Outputs
# =============================================================================

output "frontend_api_role_arn" {
  description = "ARN of IAM role for Frontend API (Pod Identity)"
  value       = aws_iam_role.frontend_api.arn
}

output "frontend_api_role_name" {
  description = "Name of IAM role for Frontend API"
  value       = aws_iam_role.frontend_api.name
}

# =============================================================================
# Configuration Summary (for Helm values)
# =============================================================================

output "authz_configuration_summary" {
  description = "Summary of authz infrastructure configuration for application config"
  value = {
    dynamodb = {
      region = data.aws_region.current.id
      tables = {
        accounts    = aws_dynamodb_table.accounts.name
        admins      = aws_dynamodb_table.admins.name
        groups      = aws_dynamodb_table.groups.name
        members     = aws_dynamodb_table.members.name
        policies    = aws_dynamodb_table.policies.name
        attachments = aws_dynamodb_table.attachments.name
      }
    }
    iam = {
      frontendApiRoleArn = aws_iam_role.frontend_api.arn
    }
  }
}

# =============================================================================
# All Table Names (for easy reference)
# =============================================================================

output "table_names" {
  description = "Map of all DynamoDB table names"
  value       = local.table_names
}

output "table_arns" {
  description = "Map of all DynamoDB table ARNs"
  value = {
    accounts    = aws_dynamodb_table.accounts.arn
    admins      = aws_dynamodb_table.admins.arn
    groups      = aws_dynamodb_table.groups.arn
    members     = aws_dynamodb_table.members.arn
    policies    = aws_dynamodb_table.policies.arn
    attachments = aws_dynamodb_table.attachments.arn
  }
}
