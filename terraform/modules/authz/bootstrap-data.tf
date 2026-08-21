# =============================================================================
# Bootstrap Account Data
#
# Automatically provisions initial privileged accounts in the DynamoDB accounts table.
# This solves the bootstrap problem: the platform-api needs at least one privileged
# account in the table to authorize requests, including requests to provision more accounts.
#
# IMPORTANT: Only use this for initial bootstrap accounts. Additional accounts should
# be provisioned through the platform-api itself.
# =============================================================================

locals {
  # Create account items for each bootstrap account
  bootstrap_account_items = {
    for account_id in var.bootstrap_accounts : account_id => {
      accountId  = { S = account_id }
      privileged = { BOOL = true }
      createdAt  = { S = timestamp() }
      createdBy  = { S = "terraform-bootstrap" }
    }
  }
}

# Insert each account into the accounts table
resource "aws_dynamodb_table_item" "bootstrap_accounts" {
  for_each = local.bootstrap_account_items

  table_name = aws_dynamodb_table.accounts.name
  hash_key   = aws_dynamodb_table.accounts.hash_key

  item = jsonencode(each.value)

  # Ignore changes after initial creation - this allows the platform-api to manage
  # these accounts going forward without Terraform trying to revert changes
  lifecycle {
    ignore_changes = [item]
  }
}
