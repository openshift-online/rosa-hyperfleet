locals {
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  common_tags = {
    function  = "cluster-infra"
    module    = "vpc"
    ManagedBy = "terraform"
  }
}
