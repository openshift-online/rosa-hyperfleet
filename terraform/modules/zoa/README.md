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

MC Lambdas access RC data via IAM roles with OU-scoped trust policies:

- `data_access` role: MC Lambdas assume this for DynamoDB (executions, audit, sessions) + S3 + KMS. Table names in Lambda env; no DynamoDB table resource policies.
- `uploader` role: MC Lambdas assume this for scoped S3 upload credentials in async Jobs

Trust policies use `aws:PrincipalOrgPaths` — no MC account IDs are hardcoded. Any new MC account within the OU automatically gets access on first execution.

## Image Mirroring

ECR repos are populated via `null_resource` + `skopeo copy` from the source registry (e.g., Quay). The mirror is idempotent: if the tag exists, it skips. If `skopeo` is not available in the platform image, the provisioner fails with a clear error.
