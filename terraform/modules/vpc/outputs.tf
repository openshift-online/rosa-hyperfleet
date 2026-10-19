# =============================================================================
# VPC Module Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = aws_subnet.public[*].id
}

output "control_plane_subnet_ids" {
  description = "Private subnet IDs for the EKS control plane / VPC Links (first control_plane_az_count AZs of the span)."
  value       = slice(aws_subnet.private[*].id, 0, local.control_plane_az_count)
}

output "nat_gateway_ids" {
  description = "IDs of NAT Gateways"
  value       = aws_nat_gateway.main[*].id
}

output "cluster_security_group_id" {
  description = "Security group ID for EKS cluster control plane"
  value       = aws_security_group.eks_cluster.id
}

output "vpc_endpoints_security_group_id" {
  description = "Security group ID for VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}

output "availability_zones" {
  description = "Resolved availability zones used for subnet placement"
  value       = local.azs
}
