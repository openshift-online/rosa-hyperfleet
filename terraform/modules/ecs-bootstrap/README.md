# ECS Bootstrap Module

This Terraform module creates an ECS Fargate infrastructure for external ArgoCD bootstrap execution. It provides acess to secure, auditable tasks to run against the regional/management AWS accounts and EKS cluster.

## Overview

The module creates:

- **ECS Fargate Cluster**: Dedicated cluster for bootstrap operations
- **ECS Task Definition**: Containerized bootstrap execution with AWS CLI base image
- **IAM Roles**: Separate execution and task roles with minimal required permissions
- **Security Groups**: Network isolation with controlled EKS API access
- **CloudWatch Logging**: Complete audit trail for all bootstrap operations

## Usage

```hcl
module "ecs_bootstrap" {
  source = "../../../modules/ecs-bootstrap"

  vpc_id                        = module.eks_cluster.vpc_id
  private_subnets              = module.eks_cluster.private_subnets
  eks_cluster_arn              = module.eks_cluster.cluster_arn
  eks_cluster_name             = module.eks_cluster.cluster_name
  eks_cluster_security_group_id = module.eks_cluster.cluster_security_group_id
  cluster_id                   = var.regional_id  # or var.management_id
}
```

## Security Features

### Network Security

- **Private Execution**: Tasks run in private subnets without public IPs
- **Controlled Access**: Security groups allow only necessary EKS API access (port 443)

### IAM Security

- **EKS Access Entries**: Uses EKS access entry mechanism for Kubernetes RBAC - which can later receive further fine grained permissions
- **Minimal Permissions**: Task role has only required EKS and SSM permissions

### Audit Trail

- **CloudWatch Logs**: Complete logging of all bootstrap operations
- **ECS Task Tracking**: Task execution history and status
- **Infrastructure as Code**: All permissions and configuration defined in Terraform

## Inputs

| Name                          | Description                                                       | Type           | Default | Required |
| ----------------------------- | ----------------------------------------------------------------- | -------------- | ------- | :------: |
| cluster_id                    | Cluster identifier for resource naming (e.g., `regional`, `mc01`) | `string`       | n/a     |   yes    |
| vpc_id                        | VPC ID for ECS task execution                                     | `string`       | n/a     |   yes    |
| private_subnets               | Private subnet IDs for task execution                             | `list(string)` | n/a     |   yes    |
| eks_cluster_arn               | EKS cluster ARN for bootstrap configuration                       | `string`       | n/a     |   yes    |
| eks_cluster_name              | EKS cluster name for bootstrap configuration                      | `string`       | n/a     |   yes    |
| eks_cluster_security_group_id | EKS cluster security group ID                                     | `string`       | n/a     |   yes    |
| environment                   | Environment name for tagging                                      | `string`       | `"dev"` |    no    |

## Outputs

| Name                        | Description                                            |
| --------------------------- | ------------------------------------------------------ |
| ecs_cluster_arn             | ARN of the ECS cluster for bootstrap tasks             |
| task_definition_arn         | ARN of the ECS task definition for bootstrap execution |
| log_group_name              | CloudWatch log group name for bootstrap operations     |
| bootstrap_security_group_id | Security group ID for bootstrap ECS tasks              |
| private_subnets             | Private subnet IDs where bootstrap tasks run           |

## Requirements

| Name      | Version   |
| --------- | --------- |
| terraform | >= 1.15.3 |
| aws       | >= 5.0    |

## Future Enhancements

This ECS infrastructure is designed to support future SRE operations beyond bootstrap:

- **Operational Tasks**: Cluster maintenance, backup operations, monitoring setup
- **Pre-built Containers**: In the future ad-hoc script pulling will be replaced by versioned containers built through konflux
