provider "aws" {
  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
    }
  }
}

data "aws_region" "current" {}

# Call the kube-applier-dynamodb module to create the six DynamoDB tables and
# the backend IAM role for this Management Cluster.
module "kube_applier_dynamodb" {
  source = "../../modules/kube-applier-dynamodb"

  mc_name    = var.management_cluster_id
  rc_id      = var.regional_id
  aws_region = data.aws_region.current.name
  enable_pitr = var.enable_pitr

  tags = merge(
    var.tags,
    {
      ProvisioningMethod = "pipeline"
      ManagedBy          = "terraform"
    }
  )
}
