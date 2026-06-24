# kube-applier-dynamodb Module

Creates the six DynamoDB tables and backend IAM role for `kube-applier-aws` for one
Management Cluster. Runs in the **Regional Cluster account** via the `Mint-DynamoDB`
CodePipeline stage.

## Tables Created

For each MC (`mc-{mc_name}`), six tables are created:

| Table | Type | Streams |
|-------|------|---------|
| `mc-{mc}-specs-applydesires` | specs | yes (NEW_AND_OLD_IMAGES) |
| `mc-{mc}-specs-deletedesires` | specs | yes |
| `mc-{mc}-specs-readdesires` | specs | yes |
| `mc-{mc}-status-applydesires` | status | no |
| `mc-{mc}-status-deletedesires` | status | no |
| `mc-{mc}-status-readdesires` | status | no |

All tables use `PAY_PER_REQUEST` billing with `DocumentID` (string) as the partition key.

## Backend IAM Role

A single backend role (`{rc_id}-kube-applier-backend`) is created (or referenced) with:
- **Specs tables** (`mc-*-specs-*`): `PutItem`, `UpdateItem`, `DeleteItem`, `GetItem`, `Scan`, `Query`
- **Status tables** (`mc-*-status-*`): `GetItem`, `Scan`, `Query`

This role is for the future backend service that writes desires and reads status across all MCs.

## Usage

```hcl
module "kube_applier_dynamodb" {
  source = "../../modules/kube-applier-dynamodb"

  mc_name    = var.management_cluster_id
  rc_id      = var.regional_id
  aws_region = var.region
  enable_pitr = var.environment != "ephemeral"
}
```
