# =============================================================================
# Infrastructure Outputs for Bootstrap Configuration
# =============================================================================

# Cluster identification
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.regional_cluster.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.regional_cluster.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.regional_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for kubectl"
  value       = module.regional_cluster.cluster_certificate_authority_data
  sensitive   = true
}

# Networking
output "vpc_id" {
  description = "VPC ID where cluster is deployed"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs where worker nodes are deployed"
  value       = module.vpc.private_subnet_ids
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = module.vpc.cluster_security_group_id
}

output "node_security_group_id" {
  description = "EKS node/pod security group ID (Auto Mode primary SG)"
  value       = module.regional_cluster.node_security_group_id
}

# =============================================================================
# ECS Bootstrap Outputs for External Script Usage
# =============================================================================

output "ecs_cluster_arn" {
  description = "ECS cluster ARN for bootstrap tasks"
  value       = module.ecs_bootstrap.ecs_cluster_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name for bootstrap tasks"
  value       = module.ecs_bootstrap.ecs_cluster_name
}

output "ecs_task_definition_arn" {
  description = "ECS task definition ARN for bootstrap execution"
  value       = module.ecs_bootstrap.task_definition_arn
}

output "bootstrap_log_group_name" {
  description = "CloudWatch log group name for bootstrap operations"
  value       = module.ecs_bootstrap.log_group_name
}

output "bootstrap_security_group_id" {
  description = "Security group ID for bootstrap ECS tasks"
  value       = module.ecs_bootstrap.bootstrap_security_group_id
}

# =============================================================================
# ArgoCD Bootstrap Configuration Outputs
# =============================================================================

output "repository_url" {
  description = "Git repository URL for cluster configuration"
  value       = module.ecs_bootstrap.repository_url
}

output "repository_branch" {
  description = "Git branch for cluster configuration"
  value       = module.ecs_bootstrap.repository_branch
}

# =============================================================================
# Bastion Outputs (only available when enable_bastion = true)
# =============================================================================

output "bastion_ecs_cluster_name" {
  description = "ECS cluster name for bastion tasks"
  value       = var.enable_bastion ? module.bastion[0].ecs_cluster_name : null
}

output "bastion_log_group_name" {
  description = "CloudWatch log group name for bastion logs"
  value       = var.enable_bastion ? module.bastion[0].log_group_name : null
}

output "bastion_run_task_command" {
  description = "AWS CLI command to start a bastion task"
  value       = var.enable_bastion ? module.bastion[0].run_task_command : null
}

output "bastion_exec_command_template" {
  description = "AWS CLI command template to connect to a running bastion (replace <TASK_ID>)"
  value       = var.enable_bastion ? module.bastion[0].exec_command_template : null
}

output "bastion_ssm_port_forward_template" {
  description = "AWS CLI command template for SSM port forwarding (replace <TASK_ID> and <RUNTIME_ID>)"
  value       = var.enable_bastion ? module.bastion[0].ssm_port_forward_template : null
}

output "log_collector_task_family" {
  description = "Family name of the log-collector task definition"
  value       = var.enable_bastion ? module.bastion[0].log_collector_task_family : null
}

# =============================================================================
# API Gateway Outputs
# =============================================================================

output "api_gateway_invoke_url" {
  description = "API Gateway invoke URL for testing"
  value       = module.api_gateway.invoke_url
}

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = module.api_gateway.api_gateway_id
}

output "api_target_group_arn" {
  description = "Target group ARN for TargetGroupBinding in Kubernetes"
  value       = module.api_gateway.target_group_arn
}

output "thanos_target_group_arn" {
  description = "Target group ARN for Thanos Receive TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.thanos_receive_target_group_arn
}

output "thanos_query_target_group_arn" {
  description = "Target group ARN for Thanos Query Frontend TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.thanos_query_target_group_arn
}

output "rhobs_api_url" {
  description = "RHOBS API Gateway invoke URL (used for both MC remote_write and Thanos Query)"
  value       = module.rhobs_api_gateway.invoke_url
}

output "api_allowed_accounts" {
  description = "Platform API allowed accounts (comma-separated account IDs, including current account)"
  value       = join(",", local.api_allowed_accounts)
}

output "api_alb_dns_name" {
  description = "Internal ALB DNS name"
  value       = module.api_gateway.alb_dns_name
}

output "api_alb_security_group_id" {
  description = "ALB security group ID"
  value       = module.api_gateway.alb_security_group_id
}

output "api_test_command" {
  description = "awscurl command to test the API"
  value       = module.api_gateway.test_command
}

# =============================================================================
# DNS Outputs
# =============================================================================

output "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional domain (e.g. us-east-1.int0.rosa.devshift.net)"
  value       = var.environment_domain != null ? aws_route53_zone.regional[0].zone_id : null
}

output "regional_domain" {
  description = "Regional domain name (e.g. us-east-1.int0.rosa.devshift.net)"
  value       = var.environment_domain != null ? "${var.region}.${var.environment_domain}" : null
}

output "regional_name_servers" {
  description = "NS records for the regional zone"
  value       = var.environment_domain != null ? aws_route53_zone.regional[0].name_servers : null
}


output "api_domain_name" {
  description = "Custom domain name for the API (e.g. api.us-east-1.int0.rosa.devshift.net)"
  value       = module.api_gateway.api_domain_name
}

output "api_domain_regional_domain_name" {
  description = "API Gateway regional domain name — target for DNS alias/CNAME"
  value       = module.api_gateway.api_domain_regional_domain_name
}

# Maestro Infrastructure Outputs
# =============================================================================

# AWS IoT Core
output "maestro_iot_mqtt_endpoint" {
  description = "AWS IoT Core MQTT endpoint for Maestro broker connection"
  value       = module.maestro_infrastructure.iot_mqtt_endpoint
}

# RDS Database
output "maestro_rds_endpoint" {
  description = "Maestro RDS PostgreSQL endpoint (hostname:port)"
  value       = module.maestro_infrastructure.rds_endpoint
}

output "maestro_rds_address" {
  description = "Maestro RDS PostgreSQL hostname"
  value       = module.maestro_infrastructure.rds_address
}

output "maestro_rds_port" {
  description = "Maestro RDS PostgreSQL port"
  value       = module.maestro_infrastructure.rds_port
}

# Secrets Manager
output "maestro_server_cert_secret_name" {
  description = "Secrets Manager secret name for Maestro Server certificate material"
  value       = module.maestro_infrastructure.maestro_server_cert_secret_name
}

output "maestro_server_config_secret_name" {
  description = "Secrets Manager secret name for Maestro Server MQTT configuration"
  value       = module.maestro_infrastructure.maestro_server_config_secret_name
}

output "maestro_db_credentials_secret_name" {
  description = "Secrets Manager secret name for Maestro database credentials"
  value       = module.maestro_infrastructure.maestro_db_credentials_secret_name
}

# IAM Roles
output "maestro_server_role_arn" {
  description = "IAM role ARN for Maestro Server (Pod Identity)"
  value       = module.maestro_infrastructure.maestro_server_role_arn
}

# Configuration Summary
output "maestro_configuration_summary" {
  description = "Complete Maestro configuration for use in Helm values"
  value       = module.maestro_infrastructure.maestro_configuration_summary
  sensitive   = false
}

# =============================================================================
# Authorization Outputs
# =============================================================================

# DynamoDB Tables
output "authz_accounts_table_name" {
  description = "Authz accounts DynamoDB table name"
  value       = module.authz.accounts_table_name
}

output "authz_admins_table_name" {
  description = "Authz admins DynamoDB table name"
  value       = module.authz.admins_table_name
}

output "authz_groups_table_name" {
  description = "Authz groups DynamoDB table name"
  value       = module.authz.groups_table_name
}

output "authz_members_table_name" {
  description = "Authz group members DynamoDB table name"
  value       = module.authz.members_table_name
}

output "authz_policies_table_name" {
  description = "Authz policies DynamoDB table name"
  value       = module.authz.policies_table_name
}

output "authz_attachments_table_name" {
  description = "Authz attachments DynamoDB table name"
  value       = module.authz.attachments_table_name
}

# IAM Role
output "authz_frontend_api_role_arn" {
  description = "IAM role ARN for Frontend API with authz permissions (Pod Identity)"
  value       = module.authz.frontend_api_role_arn
}

# Configuration Summary
output "authz_configuration_summary" {
  description = "Complete authz configuration for use in Helm values"
  value       = module.authz.authz_configuration_summary
  sensitive   = false
}

# =============================================================================
# HyperFleet Infrastructure Outputs
# =============================================================================

# RDS Database
output "hyperfleet_rds_endpoint" {
  description = "HyperFleet RDS PostgreSQL endpoint (hostname:port)"
  value       = module.hyperfleet_infrastructure.rds_endpoint
}

output "hyperfleet_rds_address" {
  description = "HyperFleet RDS PostgreSQL hostname"
  value       = module.hyperfleet_infrastructure.rds_address
}

output "hyperfleet_rds_port" {
  description = "HyperFleet RDS PostgreSQL port"
  value       = module.hyperfleet_infrastructure.rds_port
}

output "hyperfleet_rds_database_name" {
  description = "HyperFleet PostgreSQL database name"
  value       = module.hyperfleet_infrastructure.rds_database_name
}

# Amazon MQ
output "hyperfleet_mq_amqp_endpoint" {
  description = "HyperFleet Amazon MQ AMQPS endpoint"
  value       = module.hyperfleet_infrastructure.mq_amqp_endpoint
}

output "hyperfleet_mq_console_url" {
  description = "HyperFleet RabbitMQ management console URL"
  value       = module.hyperfleet_infrastructure.mq_console_url
}

# Secrets Manager
output "hyperfleet_db_secret_name" {
  description = "Secrets Manager secret name for HyperFleet database credentials"
  value       = module.hyperfleet_infrastructure.db_secret_name
}

output "hyperfleet_mq_secret_name" {
  description = "Secrets Manager secret name for HyperFleet MQ credentials"
  value       = module.hyperfleet_infrastructure.mq_secret_name
}

# IAM Roles
output "hyperfleet_api_role_arn" {
  description = "IAM role ARN for HyperFleet API (Pod Identity)"
  value       = module.hyperfleet_infrastructure.api_role_arn
}

output "hyperfleet_sentinel_role_arn" {
  description = "IAM role ARN for HyperFleet Sentinel (Pod Identity)"
  value       = module.hyperfleet_infrastructure.sentinel_role_arn
}

output "hyperfleet_adapter_role_arn" {
  description = "IAM role ARN for HyperFleet Adapter (Pod Identity)"
  value       = module.hyperfleet_infrastructure.adapter_role_arn
}

# Configuration Summary
output "hyperfleet_configuration_summary" {
  description = "Complete HyperFleet infrastructure configuration for use in Helm values"
  value       = module.hyperfleet_infrastructure.configuration_summary
  sensitive   = true
}

# =============================================================================
# CloudWatch Exporter Outputs
# =============================================================================

output "cloudwatch_exporter_role_arn" {
  description = "IAM role ARN for CloudWatch Exporter (Pod Identity)"
  value       = module.cloudwatch_exporter.role_arn
}

# =============================================================================
# Regional OIDC Outputs
# =============================================================================

output "oidc_cloudfront_domain" {
  description = "CloudFront domain for the regional OIDC issuer URL (prefix with https://)"
  value       = module.regional_oidc.cloudfront_domain_name
}

output "oidc_bucket_name" {
  description = "S3 bucket name for regional OIDC discovery documents"
  value       = module.regional_oidc.bucket_name
}

output "oidc_bucket_arn" {
  description = "S3 bucket ARN for regional OIDC discovery documents"
  value       = module.regional_oidc.bucket_arn
}

output "oidc_bucket_region" {
  description = "AWS region of the regional OIDC S3 bucket"
  value       = module.regional_oidc.bucket_region
}

output "oidc_writer_role_arn" {
  description = "ARN of the RC-side oidc-writer IAM role (MC operators assume this for OIDC S3+KMS access)"
  value       = module.regional_oidc.oidc_writer_role_arn
}

# =============================================================================
# Thanos Infrastructure Outputs
# =============================================================================
output "thanos_helm_values" {
  description = "Helm values for Thanos Receiver chart (use with -f flag)"
  value       = module.thanos_infrastructure.helm_values
}

# =============================================================================
# Loki Infrastructure Outputs
# =============================================================================

output "loki_kms_key_arn" {
  description = "KMS key ARN for Loki S3 SSE-KMS encryption"
  value       = module.loki_infrastructure.kms_key_arn
}

output "loki_distributor_target_group_arn" {
  description = "Target group ARN for Loki Distributor TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.loki_distributor_target_group_arn
}

output "loki_query_frontend_target_group_arn" {
  description = "Target group ARN for Loki Query Frontend TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.loki_query_frontend_target_group_arn
}

# =============================================================================
# ZOA Outputs
# =============================================================================

output "zoa_table_name" {
  description = "DynamoDB table name for ZOA executions"
  value       = module.zoa.table_name
}

output "zoa_audit_table_name" {
  description = "DynamoDB table name for ZOA audit log"
  value       = module.zoa.audit_table_name
}

output "zoa_bucket_name" {
  description = "S3 bucket name for ZOA outputs"
  value       = module.zoa.bucket_name
}

output "zoa_bucket_arn" {
  description = "S3 bucket ARN for ZOA outputs (used by MC Pod Identity)"
  value       = module.zoa.bucket_arn
}

output "zoa_kms_key_arn" {
  description = "KMS key ARN for ZOA encryption (used by MC Pod Identity for S3 SSE-KMS)"
  value       = module.zoa.kms_key_arn
}

# =============================================================================
# Grafana Ingress Outputs
# =============================================================================

output "grafana_target_group_arn" {
  description = "Target group ARN for Grafana TargetGroupBinding"
  value       = var.enable_grafana_ingress && var.environment_domain != null ? module.grafana_ingress[0].target_group_arn : null
}
