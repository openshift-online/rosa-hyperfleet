# ZOA per-VPC Lambda Module

Deploys ZOA Lambda functions (API + Worker) into a target VPC with direct EKS API access.

## Architecture

Two Lambda functions per deployment:

- **API Lambda** — Function URL with native Go streaming. Handles CLI requests and sync TA execution.
- **Worker Lambda** — Standard handler. Handles reconciler, GC, reaper (EventBridge-scheduled) and async TA execution (self-invoked from reconciler).

## Usage

Called once per VPC: once for the Regional Cluster (RC) and once per Management Cluster (MC).

```hcl
module "zoa_lambda" {
  source = "../modules/zoa-lambda"

  cluster_id                = "eph-abc123-regional"
  lambda_image_uri          = "123456789.dkr.ecr.us-east-1.amazonaws.com/zoa-lambda:abc123"
  job_image_uri             = "123456789.dkr.ecr.us-east-1.amazonaws.com/zoa-runner:abc123"
  private_subnet_ids        = module.vpc.private_subnet_ids
  cluster_security_group_id = module.eks.cluster_security_group_id
  eks_cluster_endpoint      = module.eks.cluster_endpoint
  eks_cluster_ca            = module.eks.cluster_certificate_authority_data
  eks_cluster_name          = module.eks.cluster_name
  dynamodb_table_name       = module.zoa.executions_table_name
  dynamodb_table_arn        = module.zoa.executions_table_arn
  audit_table_name          = module.zoa.audit_table_name
  audit_table_arn           = module.zoa.audit_table_arn
  artifact_bucket_name      = module.zoa.artifact_bucket_name
  artifact_bucket_arn       = module.zoa.artifact_bucket_arn
  kms_key_arn               = module.zoa.kms_key_arn
  uploader_role_arn         = module.zoa.uploader_role_arn
}
```

## Cross-Account (MC → RC)

MC deployments set `data_access_role_arn` to assume a role in the RC account for DynamoDB and S3 access. The data layer always lives in the RC account.

## Timeout Hierarchy

```
Lambda hard timeout (300s) > Code-level deadline (env var) > Per-TA TimeoutSeconds
```

All deadlines are tunable via environment variables without code change. For async TAs, the reconciler adds `ASYNC_SCHEDULING_OVERHEAD_SECONDS` (default 180s) to account for GSI propagation + reconciler cadence + Job scheduling.

## EKS Access

Currently uses `AmazonEKSClusterAdminPolicy` via EKS access entry. Future: fine-grained ClusterRole + Role via Terraform Kubernetes provider (blocked by CodeBuild private networking constraints).
