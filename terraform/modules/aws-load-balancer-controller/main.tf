data "aws_partition" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      function  = "cluster-infra"
      module    = "aws-load-balancer-controller"
      Component = "aws-load-balancer-controller"
      ManagedBy = "terraform"
    }
  )
}
