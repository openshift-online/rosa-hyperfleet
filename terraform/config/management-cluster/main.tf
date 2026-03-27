provider "aws" {
  region = var.region

  # Conditionally assume role for cross-account deployment (local dev only)
  # When target_account_id is set, assume OrganizationAccountAccessRole in target account
  # In pipelines, target_account_id is empty - ambient creds are already the target account
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

# Call the EKS cluster module for management cluster infrastructure
module "management_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_type = "management-cluster"
  cluster_id   = var.management_id

  # Management cluster sizing
  node_group_min_size     = 1
  node_group_max_size     = 2
  node_group_desired_size = 1

  # Instance types (configurable via config.yaml)
  node_instance_types = var.node_instance_types
}

# Call the ECS bootstrap module for external bootstrap execution
module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.management_cluster.vpc_id
  private_subnets               = module.management_cluster.private_subnets
  eks_cluster_arn               = module.management_cluster.cluster_arn
  eks_cluster_name              = module.management_cluster.cluster_name
  eks_cluster_security_group_id = module.management_cluster.cluster_security_group_id
  cluster_id                    = var.management_id
  container_image               = var.container_image

  # ArgoCD bootstrap configuration
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
  cluster_security_group_id = module.management_cluster.cluster_security_group_id
  vpc_id                    = module.management_cluster.vpc_id
  private_subnet_ids        = module.management_cluster.private_subnets
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
# HyperShift OIDC (Private S3 + CloudFront + Pod Identity)
# =============================================================================

# =============================================================================
# CloudWatch Exporter (Pod Identity for YACE)
# =============================================================================

module "cloudwatch_exporter" {
  source = "../../modules/cloudwatch-exporter"

  cluster_name = module.management_cluster.cluster_name
}

module "hypershift_oidc" {
  source = "../../modules/hypershift-oidc"

  cluster_id       = var.management_id
  eks_cluster_name = module.management_cluster.cluster_name
}
