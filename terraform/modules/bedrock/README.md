# Bedrock account primitives

Generic Terraform for **per AWS account + Region** Bedrock onboarding:

- Foundation model **agreements** (PUBLIC offers)
- Monthly **cost budget** (alerts only)

Not tied to ZOA or boundary. HyperFleet calls this module from regional and management cluster stacks today; move the same module to dedicated per-account bootstrap Terraform when that exists.

**Model invocation logging** (Bedrock → CloudWatch metadata) is intentionally **not** managed here. Boundary workloads get `bedrock:InvokeModel` from `modules/zoa-lambda`; add account-level logging later via dedicated account bootstrap TF if compliance requires it.

## Environment gating

The module **always runs** — every `terraform apply` evaluates it regardless of environment. The `var.environment` controls **how** account-scoped singletons are created:

- **Non-ephemeral** (`integration`, `stage`, `production`): standard Terraform lifecycle. Resources are created, **owned in state**, and **updatable**. If you change a model agreement (e.g. add a new AI model) or adjust the budget threshold, `terraform apply` applies the update directly. Destroying the stack destroys the resources — which is correct because each environment has its own dedicated AWS account.
- **Ephemeral** (`ephemeral`): `data.external` probes check if the object already exists in AWS before creating. If it exists, creation is **skipped** and the resource is **not imported** into state. This means `terraform destroy` of one ephemeral stack does not remove account-wide Bedrock setup that other stacks rely on. The trade-off: updates to existing objects (e.g. new model, different budget) are **not applied** — the probe sees "exists" and skips.

The `environment` variable defaults to `"ephemeral"` so existing callers that don't pass it get the safe shared-account behavior.

## Shared pool accounts (ephemeral / CI)

Many ephemeral cluster stacks share one RC or MC AWS account. Account-scoped objects must not be owned by a single ephemeral state.

At plan time (ephemeral only), `data.external` runs `scripts/check_account_primitive.sh`. If AWS already has the agreement or budget, **create is skipped** and the object is **not imported** into this stack's state. Destroying one ephemeral stack therefore does not delete account-wide Bedrock setup for others. Non-ephemeral environments never run this script — they use standard Terraform lifecycle.

The first ephemeral stack that creates a primitive **does** hold it in state until that stack is destroyed or you migrate ownership to account bootstrap TF.

**Limitation:** if a new stack wants to introduce an improvement (e.g., a new model agreement or different budget threshold), the `data.external` probe will see the existing object and skip creation — the improvement won't be applied. To update account-scoped primitives, modify the existing owner stack or manually delete the object and let the next apply recreate it.

## Variables

See `variables.tf`. Resource names default to account-wide fixed strings (`bedrock-monthly`), not cluster IDs.
