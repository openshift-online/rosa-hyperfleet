# Bedrock account primitives

Generic Terraform for **per AWS account + Region** Bedrock onboarding:

- Foundation model **agreements** (PUBLIC offers)
- Monthly **cost budget** (alerts only)
- Optional **model invocation logging** (metadata to CloudWatch; dedicated KMS)

Not tied to ZOA or boundary. HyperFleet calls this module from regional and management cluster stacks today; move the same module to dedicated per-account bootstrap Terraform when that exists.

## Environment gating

The module **always runs** — every `terraform apply` evaluates it regardless of environment. The `var.environment` controls **how** account-scoped singletons are created:

- **Non-ephemeral** (`integration`, `stage`, `production`): standard Terraform lifecycle. Resources are created, **owned in state**, and **updatable**. If you change a model agreement (e.g. add a new AI model) or adjust the budget threshold, `terraform apply` applies the update directly. Destroying the stack destroys the resources — which is correct because each environment has its own dedicated AWS account.
- **Ephemeral** (`ephemeral`): `data.external` probes check if the object already exists in AWS before creating. If it exists, creation is **skipped** and the resource is **not imported** into state. This means `terraform destroy` of one ephemeral stack does not remove account-wide Bedrock setup that other stacks rely on. The trade-off: updates to existing objects (e.g. new model, different budget) are **not applied** — the probe sees "exists" and skips.

The `environment` variable defaults to `"ephemeral"` so existing callers that don't pass it get the safe shared-account behavior.

## Shared pool accounts (ephemeral / CI)

Many ephemeral cluster stacks share one RC or MC AWS account. Account-scoped objects must not be owned by a single ephemeral state.

At plan time (ephemeral only), `data.external` runs `scripts/check_account_primitive.sh`. If AWS already has the agreement, budget, or logging configuration, **create is skipped** and the object is **not imported** into this stack's state. Destroying one ephemeral stack therefore does not delete account-wide Bedrock setup for others. Non-ephemeral environments never run this script — they use standard Terraform lifecycle.

The first ephemeral stack that creates a primitive **does** hold it in state until that stack is destroyed or you migrate ownership to account bootstrap TF.

**Limitation:** if a new stack wants to introduce an improvement (e.g., a new model agreement, different budget threshold, or updated logging config), the `data.external` probe will see the existing object and skip creation — the improvement won't be applied. To update account-scoped primitives, modify the existing owner stack or manually delete the object and let the next apply recreate it.

## Invocation logging

When `enable_invocation_logging` is true and the account has no logging config yet, this module creates:

- KMS key `alias/bedrock-invocation-logs`
- Log group (default `/aws/bedrock/model-invocations`)
- IAM role (default `bedrock-invocation-logging`)
- `aws_bedrock_model_invocation_logging_configuration`

Workload IAM (for example boundary task `bedrock:InvokeModel`) stays in the workload module; agreements are not part of invoke policies.

## Variables

See `variables.tf`. Resource names default to account-wide fixed strings (`bedrock-monthly`, `bedrock-invocation-logging`), not cluster IDs.
