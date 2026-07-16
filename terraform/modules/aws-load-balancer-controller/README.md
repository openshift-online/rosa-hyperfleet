# AWS Load Balancer Controller Module

Creates the IAM role and EKS Pod Identity association required to run the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) on a private EKS cluster.

## Overview

The AWS Load Balancer Controller (LBC) provides the `TargetGroupBinding` CRD used by platform
services (Thanos, Loki, RHOBS API Gateway) to wire Kubernetes services to ALB target groups.
LBC replaced the load balancing functionality previously bundled with EKS Auto Mode when clusters
migrated to OSS Karpenter.

This module provisions:

- **IAM role** (`<cluster-name>-aws-load-balancer-controller`): IAM policy derived from the
  [upstream recommended policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.3/docs/install/iam_policy.json)
- **EKS Pod Identity association**: Binds the IAM role to the LBC Kubernetes ServiceAccount

The LBC Helm chart itself is deployed via ArgoCD from
`argocd/config/regional-cluster/aws-load-balancer-controller/`.

## Usage

```hcl
module "aws_load_balancer_controller" {
  source = "./terraform/modules/aws-load-balancer-controller"

  cluster_name = module.eks_cluster.cluster_name

  tags = {
    Environment = var.environment
  }
}
```

## Variables

| Name              | Description                                    | Type          | Default                          | Required |
| ----------------- | ---------------------------------------------- | ------------- | -------------------------------- | -------- |
| `cluster_name`    | Name of the EKS cluster                        | `string`      | n/a                              | yes      |
| `namespace`       | Kubernetes namespace where the LBC is deployed | `string`      | `"aws-load-balancer-controller"` | no       |
| `service_account` | Kubernetes service account name for the LBC    | `string`      | `"aws-load-balancer-controller"` | no       |
| `tags`            | Additional tags to apply to resources          | `map(string)` | `{}`                             | no       |

## Outputs

| Name                          | Description                     |
| ----------------------------- | ------------------------------- |
| `role_name`                   | IAM role name for the LBC       |
| `role_arn`                    | IAM role ARN for the LBC        |
| `pod_identity_association_id` | EKS Pod Identity association ID |

## Requirements

| Name      | Version   |
| --------- | --------- |
| terraform | >= 1.14.3 |
| aws       | >= 6.0.0  |
