provider "aws" {
  region            = var.region
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  default_tags {
    tags = merge(
      {
        app-code      = var.app_code
        service-phase = var.service_phase
        cost-center   = var.cost_center
        environment   = var.environment
        function      = "zoa"
        module        = "mc-zoa-target-ssm-provisioning"
      },
      var.eph_prefix != "" ? { ephemeral-prefix = var.eph_prefix } : {}
    )
  }
}

# MC boundary target row in RC SSM (/zoa/targets/<deployment>/<cluster>).
# Provisioned from the MC pipeline (use_rc_account), same pattern as kube-applier-dynamodb.

resource "aws_ssm_parameter" "target" {
  name = "${var.targets_ssm_prefix}/${var.cluster_id}"
  type = "String"

  value = jsonencode({
    target_id           = var.cluster_id
    deployment_name     = var.deployment_name
    target_type         = "mc"
    vpc_id              = var.vpc_id
    subnet_ids          = var.private_subnet_ids
    security_group_id   = var.security_group_id
    ecs_cluster_arn     = var.ecs_cluster_arn
    task_definition_arn = var.task_definition_arn
    function_url        = var.function_url
    account_id          = var.mc_account_id
    region              = var.region
    status              = "ready"
  })

  tags = {
    Name = "${var.cluster_id}-zoa-target"
  }
}
