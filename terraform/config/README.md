# Terraform Configurations

## CI/CD Pipelines

For the full pipeline architecture, event triggers, and lifecycle diagrams, see [Pipeline-Based Lifecycle](../../docs/design/pipeline-based-lifecycle.md).

### `central-account-bootstrap/`

Seeds the initial CodePipeline that watches the `deploy/` directory in the repository. After deploying, the GitHub CodeStar connection must be authorized manually in the AWS Console.

### `pipeline-provisioner/`

Meta-pipeline that dynamically creates per-cluster CodePipelines when regional or management cluster JSON files are committed to `deploy/`.

### `pipeline-regional-cluster/`

Three-stage CodePipeline (validate → deploy → bootstrap) for provisioning a regional cluster. Created dynamically by the pipeline provisioner.

### `pipeline-management-cluster/`

Three-stage CodePipeline (validate → deploy → bootstrap) for provisioning a management cluster. Created dynamically by the pipeline provisioner.

## Cluster Infrastructure

### `regional-cluster/`

Provisions the full regional cluster stack: EKS, VPC, API Gateway, kube-applier DynamoDB tables, RDS (hyperfleet-db), ECS bootstrap, optional CloudTrail audit logging (disabled by default; enable with `enable_cloudtrail` for compliance environments), and optional bastion.

### `management-cluster/`

Provisions a management cluster: private EKS (1–2 nodes), ECS bootstrap, kube-applier IAM, and optional bastion. Hosts customer control planes.
