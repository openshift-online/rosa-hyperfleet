# ECS Bootstrap Module

This Terraform module creates an ECS Fargate infrastructure for external ArgoCD bootstrap execution. It provides access to secure, auditable tasks to run against the regional/management AWS accounts and EKS cluster.

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

  # Karpenter inputs (from eks-cluster module outputs)
  karpenter_controller_role_arn = module.eks_cluster.karpenter_controller_role_arn
  karpenter_queue_url           = module.eks_cluster.karpenter_queue_url
  karpenter_version             = "1.13.0"
}
```

## Bootstrap Sequence

The ECS task executes the following steps in order:

1. **Clone repository**: Checks out the configured git branch
2. **Configure kubectl**: Updates kubeconfig for the private EKS cluster
3. **Wait for addons**: Polls until CoreDNS and metrics-server are Active on the `karpenter-bootstrap` node group
4. **Install Karpenter** (when `karpenter_controller_role_arn` is set): Installs Karpenter via Helm from ECR public; skipped if already deployed
5. **Apply EC2NodeClass and NodePool**: Applies the FIPS `EC2NodeClass` and cluster-type-specific workloads `NodePool` from the `eks-nodepool` chart; always applied (idempotent) so any stale spec is corrected
6. **Prewarm validation**: Schedules a lightweight pod, waits up to 8 minutes for Karpenter to provision an EC2 node and bring it Ready. Failure prints diagnostic output (NodeClass, NodePool, NodeClaims, Karpenter logs) and exits — ECS retries the task automatically
7. **Install ArgoCD**: Installs ArgoCD via Helm and creates the Application of Applications for GitOps self-management

## Security Features

### Network Security

- **Private Execution**: Tasks run in private subnets without public IPs
- **Controlled Access**: Security groups allow only necessary EKS API access (port 443)

### IAM Security

- **EKS Access Entries**: Uses EKS access entry mechanism for Kubernetes RBAC
- **Minimal Permissions**: Task role has only required EKS, SSM, and Helm/kubectl permissions

### Audit Trail

- **CloudWatch Logs**: Complete logging of all bootstrap operations including Karpenter prewarm diagnostics
- **ECS Task Tracking**: Task execution history and status
- **Infrastructure as Code**: All permissions and configuration defined in Terraform

## Inputs

| Name                            | Description                                                                                                                                               | Type           | Default | Required |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | ------- | :------: |
| `cluster_id`                    | Cluster identifier for resource naming (e.g., `regional`, `mc01`)                                                                                         | `string`       | n/a     |   yes    |
| `vpc_id`                        | VPC ID for ECS task execution                                                                                                                             | `string`       | n/a     |   yes    |
| `private_subnets`               | Private subnet IDs for task execution                                                                                                                     | `list(string)` | n/a     |   yes    |
| `eks_cluster_arn`               | EKS cluster ARN for bootstrap configuration                                                                                                               | `string`       | n/a     |   yes    |
| `eks_cluster_name`              | EKS cluster name for bootstrap configuration                                                                                                              | `string`       | n/a     |   yes    |
| `eks_cluster_security_group_id` | EKS cluster security group ID                                                                                                                             | `string`       | n/a     |   yes    |
| `karpenter_controller_role_arn` | IAM role ARN for Karpenter controller (IRSA). Set from `eks_cluster.karpenter_controller_role_arn`. When non-empty, Karpenter is installed before ArgoCD. | `string`       | `""`    |    no    |
| `karpenter_queue_url`           | SQS queue URL for Karpenter EC2 interruption handling                                                                                                     | `string`       | `""`    |    no    |
| `karpenter_version`             | Karpenter Helm chart version to install (e.g., `"1.13.0"`)                                                                                                | `string`       | `""`    |    no    |
| `environment`                   | Environment name for tagging                                                                                                                              | `string`       | `"dev"` |    no    |

## Outputs

| Name                          | Description                                            |
| ----------------------------- | ------------------------------------------------------ |
| `ecs_cluster_arn`             | ARN of the ECS cluster for bootstrap tasks             |
| `task_definition_arn`         | ARN of the ECS task definition for bootstrap execution |
| `log_group_name`              | CloudWatch log group name for bootstrap operations     |
| `bootstrap_security_group_id` | Security group ID for bootstrap ECS tasks              |
| `private_subnets`             | Private subnet IDs where bootstrap tasks run           |

## Requirements

| Name      | Version   |
| --------- | --------- |
| terraform | >= 1.14.3 |
| aws       | >= 5.0    |
