# EKS Cluster Module

Creates private EKS clusters with security-first configuration and standardized naming/tagging.

## Features

- **Deterministic Resource Naming**: Uses `cluster_id` for all resource names (e.g., `regional`, `mc01`)
- **Provider-Level Tagging**: Enforces required organizational tags via AWS provider default_tags
- **Fully Private Clusters**: EKS control plane with private endpoint only
- **GitOps Bootstrap**: Automated ArgoCD installation via ECS Fargate task for self-management
- **Security Hardening**: KMS encryption, IMDSv2 enforcement, and network segmentation
- **High Availability**: Multi-AZ NAT Gateways for fault-tolerant egress connectivity
- **OSS Karpenter**: Node provisioning via Karpenter v1 with FIPS-validated EC2NodeClass

## Security & Scalability Enhancements

### Network Security

- **KMS Encryption**: Kubernetes secrets encrypted at rest using customer-managed keys
- **Dedicated Security Groups**: VPC endpoints use isolated security groups (port 443 from VPC CIDR only)
- **Restricted Egress**: Cluster egress limited to HTTPS for container registries and VPC internal traffic
- **EKS Authentication**: Configured for API_AND_CONFIG_MAP mode

### High Availability Network Architecture

- **Multi-AZ NAT Deployment**: One NAT Gateway per availability zone eliminates single points of failure
- **Per-AZ Route Tables**: Traffic distribution across availability zones for fault isolation
- **Improved Resilience**: AZ outages don't impact other zones' external connectivity

## Naming Convention

All resources are named using the `cluster_id` variable passed to the module (e.g., `regional`, `mc01`, or `xg4y-regional` in CI).

**Examples:**

- EKS Cluster: `mc01`
- VPC: `mc01-vpc`
- IAM Roles: `mc01-cluster-role`
- KMS Alias: `alias/mc01-eks-secrets`

Resource names are deterministic — no random suffixes. An optional CI prefix (e.g., `xg4y-`) provides isolation when multiple clusters share the same AWS account. Environment is applied as a tag, not embedded in resource names.

## Required Provider Configuration

**IMPORTANT**: You must configure the required tags in your AWS provider's `default_tags`:

```hcl
provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = {
      app-code      = "APP001"        # CMDB Application ID (required)
      service-phase = "development"   # development, staging, or production (required)
      cost-center   = "123"          # 3-digit cost center code (required)
    }
  }
}
```

## Usage

### Management Cluster

```hcl
module "management_cluster" {
  source = "./terraform/modules/eks-cluster"

  cluster_id   = var.management_id
  cluster_type = "management-cluster"

  # Optional cluster configuration
  cluster_version = "1.34"
}
```

### Regional Cluster

```hcl
module "regional_cluster" {
  source = "./terraform/modules/eks-cluster"

  cluster_id   = var.regional_id
  cluster_type = "regional-cluster"

}
```

## Variables

| Name                            | Description                                                                                                                                              | Type           | Default                                                 | Required |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | ------------------------------------------------------- | -------- |
| `cluster_id`                    | Deterministic cluster identifier for resource naming (e.g., `regional`, `mc01`)                                                                          | `string`       | n/a                                                     | yes      |
| `cluster_type`                  | Type of cluster: `regional-cluster` or `management-cluster`                                                                                              | `string`       | n/a                                                     | yes      |
| `cluster_version`               | Kubernetes version                                                                                                                                       | `string`       | `"1.34"`                                                | no       |
| `vpc_cidr`                      | VPC CIDR block                                                                                                                                           | `string`       | `"10.0.0.0/16"`                                         | no       |
| `availability_zones`            | List of availability zones (auto-detected if empty)                                                                                                      | `list(string)` | `[]`                                                    | no       |
| `private_subnet_cidrs`          | CIDR blocks for private subnets                                                                                                                          | `list(string)` | `["10.0.0.0/18", "10.0.64.0/18", "10.0.128.0/18"]`      | no       |
| `public_subnet_cidrs`           | CIDR blocks for public subnets                                                                                                                           | `list(string)` | `["10.0.192.0/22", "10.0.196.0/22", "10.0.200.0/22"]`   | no       |
| `enable_pod_security_standards` | Enable Pod Security Standards                                                                                                                            | `bool`         | `true`                                                  | no       |
| `ami_kms_key_arn`               | ARN of the Red Hat KMS key encrypting FIPS AMI EBS snapshots. When set, adds `kms:Decrypt` and `kms:CreateGrant` to Karpenter node and controller roles. | `string`       | `""`                                                    | no       |
| `bootstrap_enabled`             | Enable ArgoCD bootstrap for GitOps management                                                                                                            | `bool`         | `true`                                                  | no       |
| `argocd_namespace`              | Kubernetes namespace for ArgoCD installation                                                                                                             | `string`       | `"argocd"`                                              | no       |
| `argocd_chart_version`          | ArgoCD Helm chart version                                                                                                                                | `string`       | `"9.3.0"`                                               | no       |
| `bootstrap_repository_url`      | Git repository URL for ArgoCD configuration                                                                                                              | `string`       | `"https://github.com/openshift-online/rosa-hyperfleet"` | no       |
| `bootstrap_repository_branch`   | Git branch to track                                                                                                                                      | `string`       | `"main"`                                                | no       |

## Outputs

| Name                                   | Description                                                                              |
| -------------------------------------- | ---------------------------------------------------------------------------------------- |
| `cluster_name`                         | EKS cluster name (same as `cluster_id`)                                                  |
| `cluster_endpoint`                     | EKS cluster API endpoint                                                                 |
| `cluster_certificate_authority_data`   | Base64 encoded certificate data                                                          |
| `vpc_id`                               | VPC ID where cluster is deployed                                                         |
| `private_subnets`                      | Private subnet IDs where worker nodes are deployed                                       |
| `cluster_security_group_id`            | EKS cluster security group ID                                                            |
| `karpenter_controller_role_arn`        | IAM role ARN for Karpenter controller (IRSA)                                             |
| `karpenter_queue_url`                  | SQS queue URL for Karpenter EC2 interruption handling                                    |
| `karpenter_node_instance_profile_name` | Instance profile name for Karpenter-provisioned nodes (matches `EC2NodeClass.spec.role`) |
| `bootstrap_report`                     | Bootstrap process information and status                                                 |

## Bootstrap Functionality

When `bootstrap_enabled` is `true`, the module automatically installs Karpenter and ArgoCD via an ECS Fargate task:

1. **ECS Fargate Task**: Executes within cluster VPC for secure bootstrap operations
2. **Tool Installation**: Downloads kubectl, helm, and AWS CLI at runtime
3. **Addon Wait**: Waits for CoreDNS and metrics-server to become Active on the `karpenter-bootstrap` node group
4. **Karpenter Install**: Installs Karpenter via Helm from ECR public (`oci://public.ecr.aws/karpenter/karpenter`)
5. **FIPS Node Setup**: Applies FIPS `EC2NodeClass` (`fips`) and cluster-type-specific workloads `NodePool`
6. **Prewarm Validation**: Provisions one Karpenter node and waits for it to be Ready before continuing
7. **ArgoCD Installation**: Installs ArgoCD via Helm with cluster-only access
8. **GitOps Configuration**: Creates Application of Applications for self-management
9. **Synchronous Execution**: Bootstrap completes during `terraform apply` with visible logs

### Karpenter Infrastructure

The module provisions Karpenter-based compute:

- **`karpenter-bootstrap` managed node group**: 2x t3.medium nodes tainted `CriticalAddonsOnly=true:NoSchedule`. Hosts Karpenter controller, CoreDNS, and metrics-server.
- **Karpenter controller IAM role**: IRSA-backed, scoped to `kube-system/karpenter` ServiceAccount with SQS, EC2, and IAM instance profile permissions.
- **Karpenter node IAM role**: Full `AmazonEKSWorkerNodePolicy`, VPC CNI, ECR pull-only, and optional KMS decrypt for FIPS AMI snapshots.
- **SQS queue**: Receives EC2 interruption events (spot reclamation, instance health, rebalance) for graceful node draining.
- **EventBridge rules**: Four rules forward EC2 lifecycle events to the SQS queue.

For the FIPS node strategy, including why Auto Mode was replaced with OSS Karpenter, see [FIPS-Only EKS Compute](../../../docs/design/fips-eks-compute.md). For Karpenter IAM role design, see [Karpenter Node Provisioning](../../../docs/design/karpenter-node-provisioning.md).

## Requirements

- Terraform >= 1.14.3
- AWS Provider >= 6.0
- Required provider `default_tags` configuration
