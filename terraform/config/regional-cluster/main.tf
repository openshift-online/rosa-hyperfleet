provider "aws" {
  region = var.region

  # FedRAMP IA-07 / SC-13: Use FIPS 140-2 validated endpoints for all AWS API
  # calls from Terraform when operating in US and GovCloud regions where FIPS
  # endpoints are available. Non-US regions (EU, AP, SA, etc.) do not have FIPS
  # endpoints; enabling them there would cause all API calls to fail.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  # Conditionally assume role for cross-account deployment (local dev only)
  # When target_account_id is set, assume OrganizationAccountAccessRole in target account
  # In pipelines, target_account_id is empty - ambient creds are already the target account
  dynamic "assume_role" {
    for_each = var.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-regional-${var.regional_id}"
    }
  }

  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
      environment   = var.environment
    }
  }
}

# Central account provider for cross-account DNS delegation.
# In pipelines, ambient creds are the target account (after use_mc_account),
# so this provider uses a named profile written by the buildspec script.
# For local dev, central_aws_profile is empty and ambient creds are used.
provider "aws" {
  alias             = "central"
  region            = var.region
  profile           = var.central_aws_profile != "" ? var.central_aws_profile : null
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false
}

# PagerDuty provider — requires PAGERDUTY_TOKEN environment variable.
# Only used when enable_pagerduty = true.
provider "pagerduty" {}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}

# Call the EKS cluster module for regional cluster infrastructure
module "regional_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_type = "regional-cluster"
  cluster_id   = var.regional_id

  # Instance types (configurable via config.yaml)
  node_instance_types = var.node_instance_types
}

# Call the ECS bootstrap module for external bootstrap execution
module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.regional_cluster.vpc_id
  private_subnets               = module.regional_cluster.private_subnets
  eks_cluster_arn               = module.regional_cluster.cluster_arn
  eks_cluster_name              = module.regional_cluster.cluster_name
  eks_cluster_security_group_id = module.regional_cluster.cluster_security_group_id
  cluster_id                    = var.regional_id
  container_image               = var.container_image

  # ArgoCD bootstrap configuration
  repository_url    = var.repository_url
  repository_branch = var.repository_branch

  thanos_kms_key_arn = module.thanos_infrastructure.kms_key_arn
}

# =============================================================================
# Bastion Module (Optional)
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  cluster_id                = var.regional_id
  cluster_name              = module.regional_cluster.cluster_name
  cluster_endpoint          = module.regional_cluster.cluster_endpoint
  cluster_security_group_id = module.regional_cluster.cluster_security_group_id
  vpc_id                    = module.regional_cluster.vpc_id
  private_subnet_ids        = module.regional_cluster.private_subnets
  container_image           = var.container_image
}

# =============================================================================
# API Gateway Module
# =============================================================================

module "api_gateway" {
  source = "../../modules/api-gateway"

  vpc_id                 = module.regional_cluster.vpc_id
  private_subnet_ids     = module.regional_cluster.private_subnets
  regional_id            = var.regional_id
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name

  # Custom domain (e.g. api.us-east-1.int0.rosa.devshift.net)
  api_domain_name         = var.environment_domain != null ? "api.${var.region}.${var.environment_domain}" : null
  regional_hosted_zone_id = var.environment_domain != null ? aws_route53_zone.regional[0].zone_id : null

  # Method-level throttling and observability
  metrics_enabled        = var.api_metrics_enabled
  logging_level          = var.api_logging_level
  data_trace_enabled     = var.api_data_trace_enabled
  throttling_burst_limit = var.api_throttling_burst_limit
  throttling_rate_limit  = var.api_throttling_rate_limit
}

# =============================================================================
# RHOBS API Gateway (Metrics Ingestion)
#
# Dedicated REST API for Prometheus remote_write from Management Clusters.
# Separate from the Platform API to enforce independent access control:
# only MC accounts can invoke this API via resource policy.
# =============================================================================

module "rhobs_api_gateway" {
  source = "../../modules/rhobs-api-gateway"

  regional_id  = var.regional_id
  vpc_link_id  = module.api_gateway.vpc_link_id
  alb_arn      = module.api_gateway.alb_arn
  alb_dns_name = module.api_gateway.alb_dns_name
}

# =============================================================================
# Regional DNS Zone (Optional)
#
# When environment_domain is set, creates:
# - Regional hosted zone (<region>.<environment_domain>) in the RC account
# - NS delegation records in the environment zone (central account)
# =============================================================================

resource "aws_route53_zone" "regional" {
  count = var.environment_domain != null ? 1 : 0

  name = "${var.region}.${var.environment_domain}"

  tags = {
    Name = "${var.region}.${var.environment_domain}"
  }
}

# NS delegation from the environment zone (central account) to the regional zone
resource "aws_route53_record" "regional_delegation" {
  count    = var.environment_domain != null && var.environment_hosted_zone_id != null ? 1 : 0
  provider = aws.central

  zone_id = var.environment_hosted_zone_id
  name    = "${var.region}.${var.environment_domain}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.regional[0].name_servers
}

# Maestro Infrastructure Module
# =============================================================================

# Call the Maestro infrastructure module for MQTT-based orchestration
module "maestro_infrastructure" {
  source = "../../modules/maestro-infrastructure"

  # Required variables from EKS cluster
  regional_id                           = var.regional_id
  vpc_id                                = module.regional_cluster.vpc_id
  private_subnets                       = module.regional_cluster.private_subnets
  eks_cluster_name                      = module.regional_cluster.cluster_name
  eks_cluster_security_group_id         = module.regional_cluster.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  # Bastion access (if enabled)
  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : null

  # Database configuration (adjust for production)
  db_instance_class      = var.maestro_db_instance_class
  db_multi_az            = var.maestro_db_multi_az
  db_deletion_protection = var.maestro_db_deletion_protection

  # MQTT topic prefix
  mqtt_topic_prefix = var.maestro_mqtt_topic_prefix

  # IoT Core logging
  iot_log_level = var.iot_log_level
}

# =============================================================================
# Authorization Module
# =============================================================================

# Call the Authz module for Cedar/AVP-based authorization
module "authz" {
  source = "../../modules/authz"

  regional_id      = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  # DynamoDB configuration
  billing_mode                  = var.authz_billing_mode
  enable_point_in_time_recovery = var.authz_enable_pitr
  enable_deletion_protection    = var.authz_deletion_protection

  # Pod Identity configuration
  frontend_api_namespace       = var.authz_frontend_api_namespace
  frontend_api_service_account = var.authz_frontend_api_service_account

  # Bootstrap privileged accounts (current account + any additional allowed accounts)
  # Use distinct() to remove any duplicate account IDs
  bootstrap_accounts = distinct(compact(split(",", var.api_additional_allowed_accounts != "" ? "${data.aws_caller_identity.current.account_id},${var.api_additional_allowed_accounts}" : data.aws_caller_identity.current.account_id)))
}

# =============================================================================
# HyperFleet Infrastructure Module
# =============================================================================

# Call the HyperFleet infrastructure module for cluster lifecycle management
module "hyperfleet_infrastructure" {
  source = "../../modules/hyperfleet-infrastructure"

  # Required variables from EKS cluster
  regional_id                           = var.regional_id
  vpc_id                                = module.regional_cluster.vpc_id
  private_subnets                       = module.regional_cluster.private_subnets
  eks_cluster_name                      = module.regional_cluster.cluster_name
  eks_cluster_security_group_id         = module.regional_cluster.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  # Bastion access (if enabled)
  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : null

  # Database configuration
  db_instance_class      = var.hyperfleet_db_instance_class
  db_multi_az            = var.hyperfleet_db_multi_az
  db_deletion_protection = var.hyperfleet_db_deletion_protection

  # Message queue configuration
  mq_instance_type   = var.hyperfleet_mq_instance_type
  mq_deployment_mode = var.hyperfleet_mq_deployment_mode
}

# =============================================================================
# CloudTrail Module (FedRAMP AU-12)
# =============================================================================

module "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  source = "../../modules/cloudtrail"

  cluster_id  = var.regional_id
  environment = var.environment
}

# =============================================================================
# PagerDuty Service (Optional)
# =============================================================================

module "pagerduty_service" {
  count  = var.enable_pagerduty ? 1 : 0
  source = "../../modules/pagerduty-service"

  regional_id          = var.regional_id
  environment          = var.environment
  region               = var.region
  ci_prefix            = var.ci_prefix
  escalation_policy_id = var.pagerduty_escalation_policy_id
  eks_cluster_name     = module.regional_cluster.cluster_name
}

# =============================================================================
# Thanos Infrastructure Module (Observability)
# =============================================================================
module "thanos_infrastructure" {
  source = "../../modules/thanos-infrastructure"

  cluster_id       = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  # Optional: customize retention and namespace
  metrics_retention_days = var.thanos_metrics_retention_days
  thanos_namespace       = var.thanos_namespace
  thanos_service_account = var.thanos_service_account
}
