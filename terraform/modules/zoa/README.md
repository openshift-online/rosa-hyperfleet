# ZOA Data Layer Module

Manages the shared ZOA data layer deployed once per region in the Regional Cluster (RC) account.

## Resources

- **DynamoDB** — Three tables (all KMS-encrypted, TTL default 365d via `DYNAMODB_TTL_DAYS` on writers):
  - **Executions** — PK `executionId`; GSIs `target-status-index`, `date-bucket-index`
  - **Audit** — PK `accountId`, SK `timestamp`; GSI `date-bucket-index`
  - **Boundary sessions** — PK `sessionId`; GSIs `task-id-index`, `status-deadline-index`, `date-bucket-index`
- **S3** — Artifact bucket for TA output, logs, and large files
- **KMS** — Regional CMK for DynamoDB, S3, boundary/Lambda CloudWatch Logs, and ECS Exec encryption (see `kms.tf`)
- **IAM** — Uploader role (for async Job S3 uploads), data-access role (for MC cross-account access)
- **ECR** — Container image repositories for Lambda and runner images

Boundary **targets** (VPC, subnets, ECS ARNs, API Function URL) are registered in SSM by `modules/zoa-lambda`, not in this module. See the comment block at the end of `dynamodb.tf`.

## Cross-Account Access Model

MC Lambdas access RC data by assuming IAM roles in the RC account:

- `data_access` role: MC Lambdas assume this for DynamoDB (executions, audit, sessions), S3, and KMS. Lambdas receive table names via environment variables.
- `uploader` role: MC Lambdas assume this for scoped S3 upload credentials in async Jobs

`data_access` and `uploader` trust policies enumerate each MC `{management_id}-zoa-lambda` execution role ARN from `management_clusters` (regional-cluster locals). S3/KMS key policies may still use OU paths for CloudWatch and ECR; add new MCs via config + RC apply.

RC Access Lambda assumes per-MC `*-zoa-boundary-access` and `*-zoa-boundary-exec-scoped` roles using the same fleet list (`module.zoa-access`).

## Image Mirroring

ECR repos are populated via `null_resource` + `skopeo copy` from the source registry (e.g., Quay). The mirror is idempotent: if the tag exists, it skips. If `skopeo` is not available in the platform image, the provisioner fails with a clear error.
