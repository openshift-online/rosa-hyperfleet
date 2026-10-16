# ZOA Access module (RC only)

Session control plane: Access Lambda (`HANDLER_MODE=access`), Function URL (IAM auth), central-trusted invoker role, deployment discovery SSM in the **Central account** at `/zoa/deployments/<deployment_name>` (**primary + replica** SSM regions from regional-cluster config).

## Access Lambda execution role (split with `zoa-lambda`)

One IAM role in AWS; two Terraform owners by design (apply order, not naming hacks):

| Layer                      | Module                                                         | What it manages                                                                                                                                                                 |
| -------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Role shell**             | `zoa-lambda` (`access-trust-role.tf`, RC `target_type = "rc"`) | `aws_iam_role` with Lambda trust only. Boundary `boundary-access` / `exec-scoped` roles trust this **ARN** in the same module.                                                  |
| **Permissions + function** | **`zoa-access`** (this module)                                 | Inline policies (DynamoDB sessions/audit, ECS RunTask, STS to boundary roles, SSM, KMS, ECR), `AWSLambdaBasicExecutionRole`, `aws_lambda_function`, Function URL, invoker role. |

RC stack order: `module.zoa_lambda` → `module.zoa_access` (one-way; no constructed IAM ARNs).

Inputs **`lambda_execution_role_arn`** and **`lambda_execution_role_name`** come from **`module.zoa_lambda`** outputs.

On **destroy**, this module is removed first (function + policies), then `zoa-lambda` removes the role shell.

MC stacks do **not** call this module; MC boundary trust uses **`zoa_access_lambda_role_arn`** from RC Terraform state (read by `provision-infra-mc.sh` after RC apply). RC Access STS `AssumeRole` uses per-MC account id + `*-zoa-boundary-*` role name patterns from `management_clusters`.

See also [`../zoa-lambda/README.md`](../zoa-lambda/README.md).
