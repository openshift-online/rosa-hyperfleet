# ZOA per-VPC Lambda Module

Deploys ZOA Lambda functions (API + Worker) and **ZOA Boundary** (ECS Fargate) into a target VPC with direct EKS API access. One module per RC or MC cluster avoids a Terraform dependency cycle between API Lambda and boundary.

## Architecture

- **API Lambda** — Function URL with native Go streaming. Handles CLI requests and sync TA execution.
- **Worker Lambda** — Standard handler. Handles reconciler, GC, reaper (EventBridge-scheduled) and async TA execution (self-invoked from reconciler).
- **Boundary ECS** — Audited SRE sessions via ECS Exec; task env uses this module's API Function URL.
- **RC only:** shell IAM role for the ZOA Access Lambda (`aws_iam_role.access_lambda`); `module.zoa-access` attaches policies and the function. Boundary trust policies reference that role's ARN in this module.

Terraform layout: `main.tf` (Lambda + SSM), `boundary-*.tf`, `access-trust-role.tf`.

### Access execution role vs `zoa-access`

| In `zoa-lambda`                                         | In `zoa-access`                                         |
| ------------------------------------------------------- | ------------------------------------------------------- |
| `access-trust-role.tf`: IAM role + Lambda service trust | Inline IAM policies (DynamoDB, ECS, STS, SSM, KMS, ECR) |
| Outputs `access_lambda_role_arn` / `name`               | `aws_lambda_function`, Function URL, invoker role       |

Session permissions stay in `zoa-access` so apply/destroy order stays one-way. See [`../zoa-access/README.md`](../zoa-access/README.md).

## Usage

Called once per VPC: once for the Regional Cluster (RC) and once per Management Cluster (MC).

```hcl
module "zoa_lambda" {
  source = "../modules/zoa-lambda"

  cluster_id                = "eph-abc123-regional"
  target_type         = "rc" # or "mc" for management-cluster ZOA
  lambda_image_uri          = "123456789.dkr.ecr.us-east-1.amazonaws.com/zoa-lambda:abc123"
  job_image_uri             = "123456789.dkr.ecr.us-east-1.amazonaws.com/zoa-runner:abc123"
  private_subnet_ids        = module.vpc.private_subnet_ids
  cluster_security_group_id = module.eks.cluster_security_group_id
  eks_cluster_endpoint      = module.eks.cluster_endpoint
  eks_cluster_ca            = module.eks.cluster_certificate_authority_data
  eks_cluster_name          = module.eks.cluster_name
  dynamodb_table_name       = module.zoa.table_name
  audit_table_name          = module.zoa.audit_table_name
  artifact_bucket_name      = module.zoa.artifact_bucket_name
  artifact_bucket_arn       = module.zoa.artifact_bucket_arn
  kms_key_arn               = module.zoa.kms_key_arn
  uploader_role_arn         = module.zoa.uploader_role_arn
  vpc_id                    = module.vpc.vpc_id
  boundary_image            = var.zoa_boundary_image
  deployment_name           = var.deployment_name
  sessions_table_name       = module.zoa.sessions_table_name
  targets_ssm_prefix        = "/zoa/targets/${var.deployment_name}"
}
```

After apply, wire **`module.zoa_access`** with boundary outputs and `access_lambda_role_*` from **`module.zoa_lambda`** (RC only).

## Cross-Account (MC → RC)

MC deployments set `data_access_role_arn` to assume a role in the RC account for DynamoDB and S3 access. The data layer always lives in the RC account.

RC target metadata uses `aws_ssm_parameter.zoa_target` when `targets_ssm_prefix` is set (RC regional-cluster only). MC stacks omit that variable; MC targets use the **Provision-McZoaTargetSSM** pipeline stage (`mc-zoa-target-ssm-provisioning`).

## Timeout Hierarchy

```
Lambda hard timeout (300s) > Code-level deadline (env var) > Per-TA TimeoutSeconds
```

All deadlines are tunable via environment variables without code change. For async TAs, the reconciler adds `ASYNC_SCHEDULING_OVERHEAD_SECONDS` (default 180s) to account for GSI propagation + reconciler cadence + Job scheduling.

## EKS Access

Currently uses `AmazonEKSClusterAdminPolicy` via EKS access entry. Future: fine-grained ClusterRole + Role via Terraform Kubernetes provider (blocked by CodeBuild private networking constraints).
