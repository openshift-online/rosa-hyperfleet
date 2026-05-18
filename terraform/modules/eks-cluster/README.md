# EKS Cluster Module

Creates private EKS clusters with security-first configuration and standardized naming/tagging.

## Features

- **Deterministic Resource Naming**: Uses `cluster_id` for all resource names (e.g., `regional`, `mc01`)
- **Provider-Level Tagging**: Enforces required organizational tags via AWS provider default_tags
- **Fully Private Clusters**: EKS control plane with private endpoint only
- **GitOps Bootstrap**: Automated ArgoCD installation via ECS Fargate task for self-management
- **Security Hardening**: KMS encryption, IMDSv2 enforcement, and network segmentation
- **High Availability**: Multi-AZ NAT Gateways for fault-tolerant egress connectivity

## Security & Scalability Enhancements

### Network Security

- **KMS Encryption**: Kubernetes secrets encrypted at rest using customer-managed keys
- **Dedicated Security Groups**: VPC endpoints use isolated security groups (port 443 from VPC CIDR only)
- **Restricted Egress**: Cluster egress limited to HTTPS for container registries and VPC internal traffic
- **Auto Mode Authentication**: EKS authentication configured for API_AND_CONFIG_MAP mode

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
  cluster_version         = "1.34"
  node_instance_types     = ["t3.medium", "t3a.medium"]
  node_group_desired_size = 1
  node_group_min_size     = 1
  node_group_max_size     = 2
}
```

### Regional Cluster

```hcl
module "regional_cluster" {
  source = "./terraform/modules/eks-cluster"

  cluster_id   = var.regional_id
  cluster_type = "regional-cluster"

  # Optional cluster configuration
  node_group_desired_size = 2
  node_group_min_size     = 1
  node_group_max_size     = 4
}
```

## Variables

| Name                            | Description                                                                     | Type           | Default                                                        | Required |
| ------------------------------- | ------------------------------------------------------------------------------- | -------------- | -------------------------------------------------------------- | -------- |
| `cluster_id`                    | Deterministic cluster identifier for resource naming (e.g., `regional`, `mc01`) | `string`       | n/a                                                            | yes      |
| `cluster_type`                  | Type of cluster: `regional-cluster` or `management-cluster`                     | `string`       | n/a                                                            | yes      |
| `cluster_version`               | Kubernetes version                                                              | `string`       | `"1.34"`                                                       | no       |
| `vpc_cidr`                      | VPC CIDR block                                                                  | `string`       | `"10.0.0.0/16"`                                                | no       |
| `availability_zones`            | List of availability zones (auto-detected if empty)                             | `list(string)` | `[]`                                                           | no       |
| `private_subnet_cidrs`          | CIDR blocks for private subnets                                                 | `list(string)` | `["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]`                | no       |
| `public_subnet_cidrs`           | CIDR blocks for public subnets                                                  | `list(string)` | `["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]`          | no       |
| `node_instance_types`           | EC2 instance types for nodes                                                    | `list(string)` | `["t3.medium", "t3a.medium"]`                                  | no       |
| `node_group_desired_size`       | Desired number of nodes                                                         | `number`       | `2`                                                            | no       |
| `node_group_min_size`           | Minimum number of nodes                                                         | `number`       | `1`                                                            | no       |
| `node_group_max_size`           | Maximum number of nodes                                                         | `number`       | `4`                                                            | no       |
| `node_disk_size`                | EBS volume size for nodes (GiB)                                                 | `number`       | `20`                                                           | no       |
| `enable_pod_security_standards` | Enable Pod Security Standards                                                   | `bool`         | `true`                                                         | no       |
| `bootstrap_enabled`             | Enable ArgoCD bootstrap for GitOps management                                   | `bool`         | `true`                                                         | no       |
| `argocd_namespace`              | Kubernetes namespace for ArgoCD installation                                    | `string`       | `"argocd"`                                                     | no       |
| `argocd_chart_version`          | ArgoCD Helm chart version                                                       | `string`       | `"9.3.0"`                                                      | no       |
| `bootstrap_repository_url`      | Git repository URL for ArgoCD configuration                                     | `string`       | `"https://github.com/openshift-online/rosa-regional-platform"` | no       |
| `bootstrap_repository_branch`   | Git branch to track                                                             | `string`       | `"main"`                                                       | no       |

## Outputs

| Name                                 | Description                                        |
| ------------------------------------ | -------------------------------------------------- |
| `cluster_name`                       | EKS cluster name (same as `cluster_id`)            |
| `cluster_endpoint`                   | EKS cluster API endpoint                           |
| `cluster_certificate_authority_data` | Base64 encoded certificate data                    |
| `vpc_id`                             | VPC ID where cluster is deployed                   |
| `private_subnets`                    | Private subnet IDs where worker nodes are deployed |
| `cluster_security_group_id`          | EKS cluster security group ID                      |
| `bootstrap_report`                   | Bootstrap process information and status           |

## Bootstrap Functionality

When `bootstrap_enabled` is `true`, the module automatically installs ArgoCD for GitOps management:

1. **ECS Fargate Task**: Executes within cluster VPC for secure bootstrap operations
2. **Tool Installation**: Downloads kubectl, helm, and AWS CLI at runtime
3. **FIPS Node Setup**: Applies FIPS NodeClass and cluster-type-specific workloads NodePool
4. **Addon Wait**: Waits for CoreDNS and metrics-server addons to become Active
5. **ArgoCD Installation**: Installs ArgoCD via Helm with cluster-only access
6. **GitOps Configuration**: Creates Application of Applications for self-management
7. **Synchronous Execution**: Bootstrap completes during `terraform apply` with visible logs

### Bootstrap Process

The ECS bootstrap task:

- Runs in the cluster's private subnets for network access
- Updates kubeconfig using EKS access entries and Pod Identity
- Applies a FIPS-validated Bottlerocket NodeClass (`fips`) and a workloads NodePool
- Waits for CoreDNS and metrics-server to be Active (scheduled on the built-in `system` pool)
- Installs ArgoCD using Helm from the official repository
- Creates bootstrap application pointing to your repository
- Enables ArgoCD to take over cluster management

For the FIPS node strategy, including why the built-in `system` pool is retained and `general-purpose` is disabled, see [FIPS-Only EKS Compute](../../../docs/design/fips-eks-compute.md).

## Requirements

- Terraform >= 1.15.3
- AWS Provider >= 6.0
- Required provider `default_tags` configuration
