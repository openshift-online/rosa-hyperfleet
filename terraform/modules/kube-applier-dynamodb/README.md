# kube-applier-dynamodb Module

Creates the four DynamoDB tables and cross-account IAM policies for
`kube-applier-aws` for one Management Cluster. Runs in the **Regional Cluster
account**, invoked from `regional-cluster/main.tf`.

## Tables Created

For each MC, four tables are created:

| Table                      | Type   | GSI                | Streams |
| -------------------------- | ------ | ------------------ | ------- |
| `{mc}-specs-applydesires`  | specs  | `updateTime-index` | no      |
| `{mc}-specs-readdesires`   | specs  | `updateTime-index` | no      |
| `{mc}-status-applydesires` | status | `updateTime-index` | no      |
| `{mc}-status-readdesires`  | status | `updateTime-index` | no      |

All tables use `PAY_PER_REQUEST` billing with `documentID` (string) as the
partition key. Deletion is expressed as an `ApplyDesire` with `spec.type=Delete`
— there are no separate `deletedesires` tables.

The `updateTime-index` GSI (hash key: `shard`, range key: `updateTime`) is
present on all four tables and is used by the `hyperfleet-dynamo` two-speed
polling watcher. DynamoDB Streams are not enabled.

## Cross-Account IAM Policies

Resource-based policies are attached to each table granting the MC
kube-applier role (`{mc}-kube-applier` in the MC account) the minimum required
permissions for cross-account access:

- **Specs tables**: `DescribeTable`, `GetItem`, `BatchGetItem`, `Scan`, `Query`
  (on table and index ARNs)
- **Status tables**: `GetItem`, `BatchGetItem`, `Scan`, `Query`, `PutItem`,
  `DeleteItem` (on table and index ARNs)

## Usage

```hcl
module "kube_applier_dynamodb" {
  source = "../../modules/kube-applier-dynamodb"

  mc_name            = var.management_cluster_id
  mc_aws_account_id  = var.mc_aws_account_id
  aws_region         = var.region
  enable_pitr        = var.environment != "ephemeral"
}
```
