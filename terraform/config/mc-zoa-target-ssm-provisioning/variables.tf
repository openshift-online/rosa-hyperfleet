variable "region" {
  type = string
}

variable "cluster_id" {
  description = "Management cluster ID (SSM path suffix and target_id in JSON)."
  type        = string
}

variable "deployment_name" {
  type = string
}

variable "targets_ssm_prefix" {
  description = "e.g. /zoa/targets/us-east-1-eph-abc"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Comma-separated private subnet IDs."
  type        = string
}

variable "security_group_id" {
  type = string
}

variable "ecs_cluster_arn" {
  type = string
}

variable "task_definition_arn" {
  type = string
}

variable "function_url" {
  type = string
}

variable "mc_account_id" {
  type = string
}

variable "app_code" {
  type = string
}

variable "service_phase" {
  type = string
}

variable "cost_center" {
  type = string
}

variable "environment" {
  type = string
}

variable "eph_prefix" {
  type    = string
  default = ""
}
