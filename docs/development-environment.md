# Provisioning a Development Environment

Ephemeral environments are short-lived, isolated stacks for developing and testing the ROSA Regional Platform. All commands run inside a container on your local machine (podman or docker) and interact with shared development AWS credentials (central, regional, management accounts).

Each environment gets a unique ID that prefixes all provisioned resources, keeping environments isolated from each other. The ephemeral provider creates a managed clone of your remote branch and uses it to drive provisioning and ArgoCD syncs. To push subsequent changes into a running environment, use [Resync](#resync).

## Provision

> ⚠️ _Ensure your changes are pushed to the remote branch before provisioning — the environment is built from the remote ref, not your local working tree._

```bash
# Interactive — fzf picker for remote and branch
make ephemeral-provision

# Explicit — skip the picker
make ephemeral-provision REPO=owner/repo BRANCH=my-feature
```

On success the command prints the environment ID as well as guidance to interact with the environment.

The region is derived from the environment config (see [Customizing Your Environment](#customizing-your-environment)). By default it provisions in `us-east-1`.

To view and interact with provisioned environments at a later point in time, see [List Environments](#list-environments).

## Customizing Your Environment

By default, ephemeral environments use the preset in `config/ephemeral/` (bastion enabled, single MC in `us-east-1`). You can replace this config entirely for your local development by creating a `.ephemeral-env/` directory in the repo root.

### Structure

The `.ephemeral-env/` directory must mirror the `config/<env>/` structure:

```
.ephemeral-env/
├── defaults.yaml        # Environment-level defaults (optional)
└── us-east-1.yaml       # Region config (exactly one region file required)
```

This directory is gitignored — it only affects your local machine.

### Constraints

- Exactly **one region file** (besides `defaults.yaml`) must exist — the ephemeral provisioner deploys to a single region.
- The region file must define **`provision_mcs`** with at most **one management cluster** (only one MC account is available in the shared dev setup).
- AWS account IDs are injected automatically from credentials — do not set `aws.account_id` or `aws.management_cluster_account_id`.

### Examples

Use default topology but enable bastion and change instance types:

```yaml
# .ephemeral-env/defaults.yaml
regional_cluster:
  enable_bastion: true
  node_instance_types: ["m5.xlarge"]

management_cluster_defaults:
  enable_bastion: true
  node_instance_types: ["m5.xlarge"]
```

```yaml
# .ephemeral-env/us-east-1.yaml
provision_mcs:
  mc01: {}
```

Provision in a different region:

```yaml
# .ephemeral-env/us-east-2.yaml
provision_mcs:
  mc01: {}
```

### Applying Changes

Overrides are applied during `provision` and `resync`. To update a running environment after editing `.ephemeral-env/`:

```bash
make ephemeral-resync ID=<id>
```

## List Environments

Lists environments you have provisioned from your local machine. State is cached in the `.ephemeral-envs` file in the repo root — you can clear it at any time by deleting the file.

To interact with a previously provisioned environment, list your environments and pass the ID to the relevant command (e.g. `make ephemeral-shell ID=<id>`).

```bash
make ephemeral-list
```

Example:

```
Ephemeral environments:

ID           REPO                                          BRANCH                    REGION       STATE                  CREATED              API_URL
------------ --------------------------------------------- ------------------------- ------------ ---------------------- -------------------- -------
6bd2d3d7     typeid/rosa-regional-platform                 ROSAENG-143               us-east-1    ready                  2026-03-19T10:14:23Z https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod

To clear list: rm .ephemeral-envs
```

## Shell Access

Opens an interactive shell pre-configured with regional AWS credentials to interact directly with the API Gateway.

```bash
# Interactive — fzf picker for environment selection
make ephemeral-shell

# Explicit
make ephemeral-shell ID=6bd2d3d7
```

Example:

```
Fetching credentials from Vault (OIDC login)...
Credentials loaded (in-memory only).

ROSA Regional Platform shell

API Gateway: https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod
Region:      us-east-1

Example commands:
  awscurl --service execute-api https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod/v0/live

[root@df2f729c21c2 /]# awscurl --service execute-api https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod/v0/live
{"status":"ok"}
```

## Bastion Access

Connect to a bastion ECS task to access the Kubernetes API of the ephemeral environment's Regional Cluster (RC) or Management Cluster (MC). The bastion runs inside the cluster's VPC and has `kubectl` pre-configured with cluster-admin access.

> ⚠️ _Bastion must be enabled in your environment config (`enable_bastion: true` in `defaults.yaml`). The default ephemeral preset already has it enabled._

```bash
# Regional Cluster bastion
make ephemeral-bastion-rc

# Management Cluster bastion
make ephemeral-bastion-mc

# Explicit environment selection
make ephemeral-bastion-rc ID=6bd2d3d7
```

This fetches credentials from Vault, starts a bastion ECS task if none is running, waits for the execute command agent, and drops you into an interactive shell on the bastion. From there you can run `kubectl` commands against the cluster:

```
==> Bastion task ready
    ECS cluster: ci-f16cec-regional-bastion
    Task ID:     683c1f0af6ae4e1bba3552f2c8215bd3

==> Connecting to bastion...

bash-5.2# kubectl get nodes
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-0-1-42.ec2.internal    Ready    <none>   2h    v1.31.4-eks-aeac579
```

The bastion task stays running until explicitly stopped or until the environment is torn down (teardown automatically cleans up running bastion tasks).

## Port Forwarding

Forward ports from cluster services to your local machine through the bastion, without opening an interactive shell. This is useful for accessing the ArgoCD UI, Prometheus, Maestro, or any custom service directly from your browser.

> ⚠️ _Bastion must be enabled in your environment config (`enable_bastion: true` in `defaults.yaml`). The default ephemeral preset already has it enabled._

**Prerequisites:** `vault`, `aws`, `fzf`, `lsof` must be installed and available in your `PATH`.

```bash
# Interactive — fzf picker to choose services on the Regional Cluster
make ephemeral-port-forward-rc

# Interactive — fzf picker to choose services on the Management Cluster
make ephemeral-port-forward-mc

# Automatically forward all RC services (Maestro HTTP+gRPC, ArgoCD, Prometheus)
make ephemeral-port-forward-rc-all

# Automatically forward all MC services (ArgoCD, Prometheus)
make ephemeral-port-forward-mc-all

# Explicit environment selection
make ephemeral-port-forward-rc ID=6bd2d3d7
```

Available services per cluster type:

| Service    | RC  | MC  | Local URL                   | Notes                          |
| ---------- | --- | --- | --------------------------- | ------------------------------ |
| Maestro HTTP | Yes | No | `http://localhost:8080`   | Maestro server HTTP endpoint   |
| Maestro gRPC | Yes | No | `http://localhost:8090`   | Maestro server gRPC endpoint   |
| ArgoCD     | Yes | Yes | `https://localhost:8443`    | Admin password printed on start |
| Prometheus | Yes | Yes | `http://localhost:9090`     | Prometheus UI                  |
| Custom     | Yes | Yes | Configurable                | Prompted interactively          |

The command starts `kubectl port-forward` sessions inside the bastion, then opens SSM port-forward tunnels from your laptop to the bastion for each selected service. When ArgoCD is selected, the admin password is automatically retrieved and printed.

Press `Ctrl+C` to stop all active port-forward sessions.

Example output:

```
==> Port forwarding active. Forwarded ports:
    ArgoCD-Server: http://localhost:8443
    Prometheus:    http://localhost:9090

    ArgoCD UI:    https://localhost:8443
    Username:     admin
    Password:     abc123xyz
```

## Run E2E Tests

Run the end-to-end test suite against one of your development environments:

```bash
# Interactive — fzf picker for environment selection
make ephemeral-e2e

# Explicit
make ephemeral-e2e ID=6bd2d3d7
```

## Resync

The ephemeral environment runs from an ephemeral-provider managed clone of your branch. If you push additional changes to your remote branch after provisioning (e.g. updating a Helm chart or Terraform module), the environment won't pick them up automatically — you need to resync so the cloned branch is updated and ArgoCD syncs the changes.

Resync also re-applies the environment config, so changes to `.ephemeral-env/` are picked up alongside code changes.

```bash
# Interactive — fzf picker for environment selection
make ephemeral-resync

# Explicit
make ephemeral-resync ID=6bd2d3d7
```

## Tear Down

Destroy an environment and all its resources:

```bash
# Interactive — fzf picker for environment selection
make ephemeral-teardown

# Explicit
make ephemeral-teardown ID=6bd2d3d7
```

## Further Reading

- [Milestone 2 slides](presentations/milestone-2/slides.md) -- ephemeral provider architecture and how environments are provisioned/torn down
- [ci/ephemeral-provider/README.md](../ci/ephemeral-provider/README.md) -- ephemeral provider internals
