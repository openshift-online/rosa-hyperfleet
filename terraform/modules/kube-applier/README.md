# kube-applier Module

Creates IAM resources for the `kube-applier-aws` controller on a Management Cluster.

## Overview

The `kube-applier-aws` controller reads desire documents from DynamoDB tables in the
Regional Cluster (RC) account and applies them to the local Management Cluster Kubernetes
API. It uses EKS Pod Identity to obtain cross-account IAM credentials.

## IAM Permissions

**Specs tables** (`mc-{mc}-specs-*` in RC account) — read-only + DynamoDB Streams:
- `dynamodb:GetItem`, `dynamodb:Scan`, `dynamodb:Query`
- `dynamodb:DescribeStream`, `dynamodb:GetRecords`, `dynamodb:GetShardIterator`, `dynamodb:ListStreams`

**Status tables** (`mc-{mc}-status-*` in RC account) — read-write:
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

Tables are created separately in the RC account via the `kube-applier-dynamodb-provisioning`
Terraform config (analogous to `maestro-agent-iot-provisioning`). Six tables are created per MC:

- `mc-{mc}-specs-applydesires`
- `mc-{mc}-specs-deletedesires`
- `mc-{mc}-specs-readdesires`
- `mc-{mc}-status-applydesires`
- `mc-{mc}-status-deletedesires`
- `mc-{mc}-status-readdesires`
