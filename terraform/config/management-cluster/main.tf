provider "aws" {
  region = var.region
  # FedRAMP SC-13 / IA-07: Use FIPS 140-2 validated endpoints when available.
  # FIPS endpoints exist only in US and GovCloud regions; non-US regions (EU, AP, SA)
  # do not support FIPS endpoints and will fail if this is set to true.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  dynamic "assume_role" {
    for_each = var.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-management-${var.management_id}"
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

# =============================================================================
# VPC Module
# =============================================================================

module "vpc" {
  source = "../../modules/vpc"

  resource_name_base = var.management_id
}

# =============================================================================
# EKS Cluster
# =============================================================================

module "management_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_type                    = "management-cluster"
  cluster_id                      = var.management_id
  vpc_id                          = module.vpc.vpc_id
  vpc_cidr                        = module.vpc.vpc_cidr
  private_subnet_ids              = module.vpc.private_subnet_ids
  cluster_security_group_id       = module.vpc.cluster_security_group_id
  vpc_endpoints_security_group_id = module.vpc.vpc_endpoints_security_group_id
}

# =============================================================================
# ECS Bootstrap
# =============================================================================

module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.vpc.vpc_id
  private_subnets               = module.vpc.private_subnet_ids
  eks_cluster_arn               = module.management_cluster.cluster_arn
  eks_cluster_name              = module.management_cluster.cluster_name
  eks_cluster_security_group_id = module.vpc.cluster_security_group_id
  cluster_id                    = var.management_id
  container_image               = var.container_image

  repository_url    = var.repository_url
  repository_branch = var.repository_branch
}

# =============================================================================
# Bastion Module (Optional)
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  cluster_id                = var.management_id
  cluster_name              = module.management_cluster.cluster_name
  cluster_endpoint          = module.management_cluster.cluster_endpoint
  cluster_security_group_id = module.vpc.cluster_security_group_id
  vpc_id                    = module.vpc.vpc_id
  private_subnet_ids        = module.vpc.private_subnet_ids
  container_image           = var.container_image
}

module "maestro_agent" {
  source = "../../modules/maestro-agent"

  management_id           = var.management_id
  regional_aws_account_id = var.regional_aws_account_id
  eks_cluster_name        = module.management_cluster.cluster_name

  maestro_agent_cert_json   = file(var.maestro_agent_cert_file)
  maestro_agent_config_json = file(var.maestro_agent_config_file)
}

# =============================================================================
# DNS Pod Identity (cross-account Route53 access for external-dns + cert-manager)
# =============================================================================

module "dns_pod_identity" {
  source = "../../modules/dns-pod-identity"

  management_id              = var.management_id
  eks_cluster_name           = module.management_cluster.cluster_name
  dns_zone_operator_role_arn = var.dns_zone_operator_role_arn
}

# =============================================================================
# HyperShift OIDC (Private S3 + CloudFront + Pod Identity)
# =============================================================================

module "hypershift_oidc" {
  source = "../../modules/hypershift-oidc"

  cluster_id       = var.management_id
  eks_cluster_name = module.management_cluster.cluster_name

  oidc_bucket_name       = var.oidc_bucket_name
  oidc_bucket_arn        = var.oidc_bucket_arn
  oidc_bucket_region     = var.oidc_bucket_region
  oidc_cloudfront_domain = var.oidc_cloudfront_domain
  oidc_kms_key_arn       = var.oidc_kms_key_arn
}

# =============================================================================
# Prometheus Remote Write (MC -> RC metrics forwarding via API Gateway)
# =============================================================================

module "prometheus_remote_write" {
  source = "../../modules/prometheus-remote-write"

  management_id           = var.management_id
  regional_aws_account_id = var.regional_aws_account_id
  eks_cluster_name        = module.management_cluster.cluster_name
}

# =============================================================================
# Loki Log Forwarder (MC -> RC log forwarding via API Gateway)
# =============================================================================

module "loki_log_forwarder" {
  source = "../../modules/loki-log-forwarder"

  management_id           = var.management_id
  regional_aws_account_id = var.regional_aws_account_id
  eks_cluster_name        = module.management_cluster.cluster_name
}

# =============================================================================
# CloudWatch Exporter (Pod Identity for YACE)
# =============================================================================

module "cloudwatch_exporter" {
  source       = "../../modules/cloudwatch-exporter"
  cluster_name = module.management_cluster.cluster_name
}

# =============================================================================
# Grafana CloudWatch Logs Reader (cross-account role for RC Grafana)
# =============================================================================

module "grafana_cloudwatch_logs" {
  source                  = "../../modules/grafana-cloudwatch-logs"
  mode                    = "reader"
  cluster_name            = module.management_cluster.cluster_name
  regional_id             = var.management_id
  grafana_role_account_id = var.regional_aws_account_id
}
