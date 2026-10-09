variable "name_prefix" {
  type        = string
  description = "Optional prefix used for ephemeral resources."
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS region containing the pipelines and artifact bucket."
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection."
}
