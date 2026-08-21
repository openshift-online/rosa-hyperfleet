# ZOA Data Layer Module

Manages the shared ZOA data layer deployed once per region in the Regional Cluster (RC) account.

## Resources

- **DynamoDB** — Executions table (with GSIs: `status-index`, `target-status-index`) and audit log table
- **S3** — Artifact bucket for TA output, logs, and large files
- **KMS** — Encryption key for DynamoDB and S3
- **IAM** — Uploader role (for async Job S3 uploads), data-access role (for MC cross-account access)
- **ECR** — Container image repositories for Lambda and runner images

## Cross-Account Access Model

MC Lambdas access RC data via IAM roles with OU-scoped trust policies:

- `data_access` role: MC Lambdas assume this for DynamoDB + S3 + KMS operations
- `uploader` role: MC Lambdas assume this for scoped S3 upload credentials in async Jobs

Trust policies use `aws:PrincipalOrgPaths` — no MC account IDs are hardcoded. Any new MC account within the OU automatically gets access on first execution.

## Image Mirroring

ECR repos are populated via `null_resource` + `skopeo copy` from the source registry (e.g., Quay). The mirror is idempotent: if the tag exists, it skips. If `skopeo` is not available in the platform image, the provisioner fails with a clear error.
