data "aws_partition" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      Component = "aws-load-balancer-controller"
      ManagedBy = "terraform"
    }
  )
}
