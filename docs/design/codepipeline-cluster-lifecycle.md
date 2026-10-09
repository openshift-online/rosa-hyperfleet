# CodePipeline Cluster Lifecycle

**Status:** Current

Each RC and MC has one CodePipeline invoking its retained CodeBuild project.
Terraform owns shared resources; the cluster resource script owns dynamic
CodeBuild/CodePipeline lifecycle. The platform-image CodeBuild remains on-demand
with no webhook or dedicated pipeline.

## Lifecycle contract

`scripts/provision-cluster-resources.sh` supports:

- `create-rc`, `delete-rc`
- `create-mc`, `delete-mc`

Each action accepts one rendered cluster config. The no-argument form applies
the same operations to all rendered clusters for int/stage and ephemeral
bootstrap. Explicit create actions do not start a build; the caller supplies a
pipeline source revision. Pipeline resources are not Terraform state, allowing
an MC autoscaler to manage them without Terraform applies or per-MC pipeline
state files.

## Execution

Pipelines use a CodeStar connection with branch/file filters and V2
`SUPERSEDED` execution mode. The CodeBuild action uses the existing buildspec,
service role, and Terraform state. Ephemeral execution pins the requested
commit and teardown passes `IS_DESTROY=true` as a pipeline variable.

The ephemeral provider starts and polls pipelines, validates the underlying
CodeBuild `APPLIED=true` and `APPLIED_SHA` contract, collects CodeBuild logs,
and invokes the same per-cluster delete actions during teardown.

Existing environments require one-time cleanup of legacy CodeBuild webhook
registrations before migration. Use
`scripts/remove-codebuild-webhooks.sh <project-name>...`; it does not delete
CodeBuild projects or CodePipelines.
