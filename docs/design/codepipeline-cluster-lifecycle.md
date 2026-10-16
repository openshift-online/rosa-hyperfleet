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
bootstrap. Creating a CodePipeline starts one execution automatically; the
cluster resource script does not call `StartPipelineExecution`. Pipeline
resources are not Terraform state, allowing an MC autoscaler to manage them
without Terraform applies or per-MC pipeline state files.

## Execution

Pipelines use a CodeStar connection, branch/file push filters, and V2
`SUPERSEDED` execution mode. Ephemeral push triggers stay enabled. The provider
adopts the execution for the pushed source revision when a pipeline's filters
match, and does not independently start that same revision. On initial
provision it adopts each automatic `CreatePipeline` execution. A resume without
a branch push reuses an active execution at the same SHA or explicitly starts a
retry if the pipeline is idle. Resyncs adopt push-triggered pipelines matched
by changed paths. An unmatched pipeline reuses its previous successful
execution, or is explicitly started if it has no successful execution yet. The
CodeBuild action uses the existing buildspec, service role, and Terraform
state. Ephemeral teardown pins its requested commit and passes `IS_DESTROY=true`
as a pipeline variable. Fire-and-forget teardown waits for all MC teardowns to
succeed before starting RC teardown, then exits without waiting for RC
completion.

The ephemeral provider starts or adopts and polls pipelines, validates the underlying
CodeBuild `APPLIED=true` and `APPLIED_SHA` contract, collects CodeBuild logs,
and invokes the same per-cluster delete actions during teardown.

Existing environments require one-time cleanup of legacy CodeBuild webhook
registrations before migration. Use
`scripts/remove-codebuild-webhooks.sh <project-name>...`; it does not delete
CodeBuild projects or CodePipelines.
