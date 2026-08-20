# kube-applier Module

Creates IAM resources for the `kube-applier-aws` controller on a Management Cluster.

## Overview

The `kube-applier-aws` controller reads desire documents from DynamoDB tables in the
Regional Cluster (RC) account and applies them to the local Management Cluster Kubernetes
API. It uses EKS Pod Identity to obtain cross-account IAM credentials.

## IAM Permissions

**Specs tables** (`{mc}-specs-*` in RC account) — read-only + GSI query:

- `dynamodb:DescribeTable`, `dynamodb:GetItem`, `dynamodb:BatchGetItem`,
  `dynamodb:Scan`, `dynamodb:Query` (table and `updateTime-index` GSI ARNs)

**Status tables** (`{mc}-status-*` in RC account) — read-write:

- `dynamodb:GetItem`, `dynamodb:Scan`, `dynamodb:PutItem`, `dynamodb:DeleteItem`

## Usage

```hcl
module "kube_applier" {
  source = "../../modules/kube-applier"

  management_id    = var.management_id
  eks_cluster_name = module.management_cluster.cluster_name
  rc_aws_account_id = var.regional_aws_account_id
  aws_region       = var.region
}
```

## DynamoDB Tables

Tables are created in the RC account by the `kube-applier-dynamodb` module
(invoked from `regional-cluster/main.tf`). Four tables are created per MC:

- `{mc}-specs-applydesires`
- `{mc}-specs-readdesires`
- `{mc}-status-applydesires`
- `{mc}-status-readdesires`

Deletion is expressed as an `ApplyDesire` with `spec.type=Delete` — there are
no separate `deletedesires` tables.
