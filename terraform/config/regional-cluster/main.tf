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

# When PagerDuty is disabled, a dummy token lets the provider initialize
# without PAGERDUTY_TOKEN. When enabled, null falls through to the env var.
provider "pagerduty" {
  token                       = var.enable_pagerduty ? null : "not-configured"
  skip_credentials_validation = true
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  mc_entries     = var.management_clusters != "" ? split(",", var.management_clusters) : []
  mc_account_ids = [for entry in local.mc_entries : element(split(":", entry), 1)]
  api_allowed_accounts = distinct(compact(concat(
    [data.aws_caller_identity.current.account_id],
    local.mc_account_ids,
  )))
}

# =============================================================================
# External Secrets Operator — Pod Identity
#
# Grants ESO access to SSM Parameter Store and Secrets Manager so
# ClusterSecretStores can resolve regional secrets and config. Always
# deployed — individual feature modules should NOT create their own ESO
# pod identity associations.
# =============================================================================

resource "aws_iam_role" "external_secrets_operator" {
  name        = "${var.regional_id}-external-secrets-operator"
  description = "IAM role for External Secrets Operator"

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

  tags = {
    Name      = "${var.regional_id}-external-secrets-operator-role"
    ManagedBy = "terraform"
  }
}

resource "aws_iam_role_policy" "eso_ssm" {
  name = "${var.regional_id}-eso-ssm"
  role = aws_iam_role.external_secrets_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.regional_id}/*"
    }]
  })
}

resource "aws_iam_role_policy" "eso_secretsmanager" {
  name = "${var.regional_id}-eso-secretsmanager"
  role = aws_iam_role.external_secrets_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.regional_id}-*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets_operator" {
  cluster_name    = module.regional_cluster.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets_operator.arn

  tags = {
    Name      = "${var.regional_id}-external-secrets-operator-pod-identity"
    ManagedBy = "terraform"
  }
}

# =============================================================================
# VPC Module
# =============================================================================

module "vpc" {
  source = "../../modules/vpc"

  resource_name_base = var.regional_id
}

# =============================================================================
# EKS Cluster
# =============================================================================

module "regional_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_type                    = "regional-cluster"
  cluster_id                      = var.regional_id
  vpc_id                          = module.vpc.vpc_id
  vpc_cidr                        = module.vpc.vpc_cidr
  private_subnet_ids              = module.vpc.private_subnet_ids
  cluster_security_group_id       = module.vpc.cluster_security_group_id
  vpc_endpoints_security_group_id = module.vpc.vpc_endpoints_security_group_id
}

# =============================================================================
# ECS Bootstrap - depends on VPC + EKS
# =============================================================================

module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.vpc.vpc_id
  private_subnets               = module.vpc.private_subnet_ids
  eks_cluster_arn               = module.regional_cluster.cluster_arn
  eks_cluster_name              = module.regional_cluster.cluster_name
  eks_cluster_security_group_id = module.vpc.cluster_security_group_id
  cluster_id                    = var.regional_id
  container_image               = var.container_image

  repository_url    = var.repository_url
  repository_branch = var.repository_branch

  thanos_kms_key_arn = module.thanos_infrastructure.kms_key_arn
  loki_kms_key_arn   = module.loki_infrastructure.kms_key_arn

  management_clusters = var.management_clusters
}

# =============================================================================
# Bastion Module (Optional) - depends on VPC + EKS
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  cluster_id                = var.regional_id
  cluster_name              = module.regional_cluster.cluster_name
  cluster_endpoint          = module.regional_cluster.cluster_endpoint
  cluster_security_group_id = module.vpc.cluster_security_group_id
  vpc_id                    = module.vpc.vpc_id
  private_subnet_ids        = module.vpc.private_subnet_ids
  container_image           = var.container_image
}

# =============================================================================
# API Gateway Module - depends on VPC + EKS (needs node_security_group_id)
# =============================================================================

module "api_gateway" {
  source = "../../modules/api-gateway"

  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  regional_id            = var.regional_id
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name

  # Custom domain (e.g. api.us-east-1.int0.rosa.devshift.net)
  api_domain_name         = var.enable_api_custom_domain && var.environment_domain != null ? "api.${var.deployment_name}.${var.environment_domain}" : null
  regional_hosted_zone_id = var.environment_domain != null ? aws_route53_zone.regional[0].zone_id : null

  # Method-level throttling and observability
  metrics_enabled        = var.api_metrics_enabled
  logging_level          = var.api_logging_level
  data_trace_enabled     = var.api_data_trace_enabled
  throttling_burst_limit = var.api_throttling_burst_limit
  throttling_rate_limit  = var.api_throttling_rate_limit
}

# =============================================================================
# RHOBS API Gateway (Observability)
#
# Dedicated REST API + ALB for RHOBS traffic, fully isolated from the Platform
# API. Includes its own VPC Link, ALB, and security groups. Only MC accounts
# can invoke this API via resource policy (metrics ingestion).
# =============================================================================

module "rhobs_api_gateway" {
  source = "../../modules/rhobs-api-gateway"

  regional_id            = var.regional_id
  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name

  # Method-level observability
  metrics_enabled = var.rhobs_apigw_metrics_enabled
}

# =============================================================================
# Regional DNS Zone (Optional)
#
# When environment_domain is set, creates:
# - Regional hosted zone (<region>.<environment_domain>) in the RC account
# - NS delegation records in the environment zone (central account)
# - Initial zone shard (0.<region>.<environment_domain>) for cluster records
# =============================================================================

resource "aws_route53_zone" "regional" {
  count = var.environment_domain != null ? 1 : 0

  name = "${var.deployment_name}.${var.environment_domain}"

  tags = {
    Name = "${var.deployment_name}.${var.environment_domain}"
  }
}

# Look up the environment zone in the central account so we can create NS
# delegation without owning the zone in this state.
data "aws_route53_zone" "environment" {
  count    = var.environment_domain != null ? 1 : 0
  provider = aws.central

  name         = var.environment_domain
  private_zone = false
}

# NS delegation from the environment zone (central account) to the regional zone
resource "aws_route53_record" "regional_delegation" {
  count    = var.environment_domain != null ? 1 : 0
  provider = aws.central

  zone_id = data.aws_route53_zone.environment[0].zone_id
  name    = "${var.deployment_name}.${var.environment_domain}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.regional[0].name_servers
}

# =============================================================================
# Zone Shards (Optional)
#
# Each shard is a separate Route53 HostedZone under the regional zone,
# providing ~10k records per shard. MC operators (external-dns, cert-manager)
# create cluster records in shards. CLM assigns clusters to shards.
# =============================================================================

resource "aws_route53_zone" "zone_shard" {
  count = var.environment_domain != null ? var.zone_shard_count : 0

  name = "${count.index}.${var.deployment_name}.${var.environment_domain}"

  tags = {
    Name  = "${count.index}.${var.deployment_name}.${var.environment_domain}"
    Shard = tostring(count.index)
  }
}

# NS delegation from the regional zone to each zone shard
resource "aws_route53_record" "zone_shard_delegation" {
  count = var.environment_domain != null ? var.zone_shard_count : 0

  zone_id = aws_route53_zone.regional[0].zone_id
  name    = "${count.index}.${var.deployment_name}.${var.environment_domain}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.zone_shard[count.index].name_servers
}

# =============================================================================
# DNS Zone Operator (Cross-Account IAM for MC operators)
# =============================================================================

data "aws_ssm_parameter" "region_ou_path" {
  count           = var.environment_domain != null ? 1 : 0
  name            = "/infra/region-ou-path"
  with_decryption = true

  lifecycle {
    postcondition {
      condition     = self.value != ""
      error_message = "SSM parameter /infra/region-ou-path must not be empty. This parameter must be stored as SecureString in the RC account — see docs/environment-provisioning.md."
    }
  }
}

module "dns_zone_operator" {
  count  = var.environment_domain != null ? 1 : 0
  source = "../../modules/dns-zone-operator"

  regional_id                = var.regional_id
  regional_hosted_zone_id    = aws_route53_zone.regional[0].zone_id
  zone_shard_hosted_zone_ids = aws_route53_zone.zone_shard[*].zone_id
  region_ou_path             = data.aws_ssm_parameter.region_ou_path[0].value
}

# =============================================================================
# Maestro Infrastructure Module - VPC from vpc module, node SG from EKS
# =============================================================================

module "maestro_infrastructure" {
  source = "../../modules/maestro-infrastructure"

  # Required variables from EKS cluster
  regional_id                           = var.regional_id
  vpc_id                                = module.vpc.vpc_id
  private_subnets                       = module.vpc.private_subnet_ids
  eks_cluster_name                      = module.regional_cluster.cluster_name
  eks_cluster_security_group_id         = module.vpc.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  bastion_enabled           = var.enable_bastion
  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : null

  db_instance_class      = var.maestro_db_instance_class
  db_multi_az            = var.maestro_db_multi_az
  db_deletion_protection = var.maestro_db_deletion_protection

  mqtt_topic_prefix = var.maestro_mqtt_topic_prefix

  # IoT Core logging
  iot_log_level = var.iot_log_level
}

# =============================================================================
# Authorization Module
# =============================================================================

module "authz" {
  source = "../../modules/authz"

  regional_id      = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  billing_mode                  = var.authz_billing_mode
  enable_point_in_time_recovery = var.authz_enable_pitr
  enable_deletion_protection    = var.authz_deletion_protection

  frontend_api_namespace       = var.authz_frontend_api_namespace
  frontend_api_service_account = var.authz_frontend_api_service_account

  bootstrap_accounts = local.api_allowed_accounts
}

# =============================================================================
# ZOA (Zero Operator Access) Module
# =============================================================================

module "zoa" {
  count  = var.enable_zoa ? 1 : 0
  source = "../../modules/zoa"

  regional_id      = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  platform_api_role_id  = module.authz.frontend_api_role_name
  platform_api_role_arn = module.authz.frontend_api_role_arn
}

# =============================================================================
# HyperFleet Infrastructure Module - MQ broker provisions in parallel with EKS
# =============================================================================

module "hyperfleet_infrastructure" {
  source = "../../modules/hyperfleet-infrastructure"

  # Required variables from EKS cluster
  regional_id                           = var.regional_id
  vpc_id                                = module.vpc.vpc_id
  private_subnets                       = module.vpc.private_subnet_ids
  eks_cluster_name                      = module.regional_cluster.cluster_name
  eks_cluster_security_group_id         = module.vpc.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  bastion_enabled           = var.enable_bastion
  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : null

  db_instance_class      = var.hyperfleet_db_instance_class
  db_multi_az            = var.hyperfleet_db_multi_az
  db_deletion_protection = var.hyperfleet_db_deletion_protection

  mq_instance_type   = var.hyperfleet_mq_instance_type
  mq_deployment_mode = var.hyperfleet_mq_deployment_mode
}

# =============================================================================
# CloudWatch Exporter (Pod Identity for YACE)
# =============================================================================

module "cloudwatch_exporter" {
  source       = "../../modules/cloudwatch-exporter"
  cluster_name = module.regional_cluster.cluster_name
}

# =============================================================================
# Regional OIDC Module
#
# Provisions the shared OIDC S3 bucket and CloudFront distribution owned by
# the RC. Management Clusters write to this bucket cross-account.
# =============================================================================

module "regional_oidc" {
  source = "../../modules/regional-oidc"

  regional_id = var.regional_id
  mc_ou_path  = var.mc_ou_path
}

# =============================================================================
# Grafana CloudWatch Logs (Pod Identity for CW Logs datasource)
# =============================================================================

module "grafana_cloudwatch_logs" {
  source       = "../../modules/grafana-cloudwatch-logs"
  mode         = "primary"
  cluster_name = module.regional_cluster.cluster_name
  regional_id  = var.regional_id
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
  eph_prefix           = var.eph_prefix
  escalation_policy_id = var.pagerduty_escalation_policy_id
}

# =============================================================================
# SNS Alerting Module (Phase 2 Alert Fan-Out)
# =============================================================================

module "sns_alerting" {
  count  = var.enable_sns_alerting ? 1 : 0
  source = "../../modules/sns-alerting"

  regional_id      = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name
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

# =============================================================================
# Loki Infrastructure Module (Observability - Logs)
# =============================================================================
module "loki_infrastructure" {
  source = "../../modules/loki-infrastructure"

  cluster_id       = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  logs_retention_days  = var.loki_logs_retention_days
  loki_namespace       = var.loki_namespace
  loki_service_account = var.loki_service_account
}
