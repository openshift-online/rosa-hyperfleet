locals {
  # Sort AZ names so index-based CIDR assignment below stays stable across applies.
  sorted_names = sort(data.aws_availability_zones.available.names)

  # az_count = null: every AZ (MC PrivateLink coverage). az_count = N: first N AZs.
  azs = var.az_count != null ? slice(local.sorted_names, 0, var.az_count) : local.sorted_names

  # EKS control plane / VPC Links use the first few AZs of the span (EKS needs >=2;
  # the first 3 avoid late-alphabet AZs that may not support these services).
  control_plane_az_count = min(3, length(local.azs))

  # One subnet per AZ, carved from the VPC CIDR. Private subnets are /19 and
  # public subnets /24 for a /16 VPC, which fits up to 6 AZs without overlap.
  private_subnet_cidrs = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnet_cidrs  = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, 240 + i)]

  common_tags = {
    function  = "cluster-infra"
    module    = "vpc"
    ManagedBy = "terraform"
  }
}
