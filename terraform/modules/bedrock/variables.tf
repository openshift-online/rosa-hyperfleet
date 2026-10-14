variable "environment" {
  description = "Deployment environment name (e.g. 'ephemeral', 'integration', 'production'). When 'ephemeral', data.external probes skip-if-exists to avoid state ownership conflicts in shared pool accounts."
  type        = string
  default     = "ephemeral"
}

variable "enable_bedrock_model_agreements" {
  description = "Create aws_bedrock_foundation_model_agreement for each non-empty entry in model_agreements when not already AVAILABLE in this account/Region."
  type        = bool
  default     = true
}

variable "model_agreements" {
  description = "Foundation model ID to Bedrock PUBLIC offer ID. Empty offer ID skips that model."
  type        = map(string)
  default = {
    "anthropic.claude-sonnet-5" = "offer-2ykemehpsyf7g"
  }
}

variable "enable_cost_budget" {
  description = "Create an account-wide monthly Amazon Bedrock cost budget when budget_name does not already exist."
  type        = bool
  default     = true
}

variable "budget_name" {
  description = "AWS Budgets name for Bedrock service spend (fixed per account, not per cluster)."
  type        = string
  default     = "bedrock-monthly"
}

variable "monthly_budget_usd" {
  description = "Monthly Bedrock spend limit (USD) for budget alerts only."
  type        = number
  default     = 1000

  validation {
    condition     = var.monthly_budget_usd >= 1
    error_message = "monthly_budget_usd must be at least 1."
  }
}

variable "budget_notification_email" {
  description = "Base email for budget ACTUAL spend notifications (plus-addressed with account ID)."
  type        = string
  default     = "rosa-hyperfleet@redhat.com"

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_notification_email))
    error_message = "budget_notification_email must be a valid email address."
  }
}

variable "tags" {
  description = "Additional tags applied to Bedrock module resources."
  type        = map(string)
  default     = {}
}
