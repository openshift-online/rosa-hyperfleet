# Provisioning a Development Environment

Ephemeral environments are short-lived, isolated stacks for developing and testing the ROSA HyperFleet. All commands run inside a container on your local machine (podman or docker) and interact with shared development AWS credentials (central, regional, management accounts).

Each environment gets a unique ID that prefixes all provisioned resources, keeping environments isolated from each other. The ephemeral provider creates a managed clone of your remote branch and uses it to drive provisioning and ArgoCD syncs. To push subsequent changes into a running environment, use [Resync](#resync).

## Prerequisites

The following tools must be in `PATH` for all ephemeral environment commands:

| Tool              | Purpose                                     |
| ----------------- | ------------------------------------------- |
| `git`             | Repository operations                       |
| `python3`         | Config rendering                            |
| `uv`              | Python script runner (SAML credentials)     |
| `fzf`             | Interactive selection menus                 |
| `podman`/`docker` | Running the ephemeral environment container |

Port forwarding additionally requires `aws` and `lsof`.

### AWS Account Setup

By default, scripts look for account ID files in the `rosa-hyperfleet-internal` sibling repo:

- **Ephemeral (dev)**: `../rosa-hyperfleet-internal/infra/accounts/dev/accounts.json`
- **Integration**: `../rosa-hyperfleet-internal/infra/accounts/int/accounts.json`

If you have the internal repo checked out alongside this one, no extra setup is needed.

To override, set the env vars `RRP_ACCOUNTS_DEV` or `RRP_ACCOUNTS_INT` to point to a different file. The expected format is:

```json
{
  "admin": "<admin-account-id>",
  "central": "<central-account-id>",
  "rc": "<rc-account-id>",
  "mc": "<mc-account-id>",
  "customer": "<customer-account-id>"
}
```

(Integration accounts omit `admin`.)

Alternatively, set `RRP_AWS_PROFILES_PRESET=1` to skip the built-in credential setup entirely and manage your own AWS profiles (profiles must be named `rrp-ephemeral-{central,rc,mc,customer}` for ephemeral or `rrp-int-{rc,mc,customer}` for integration).

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

Use default topology but enable bastion and change instance families:

```yaml
# .ephemeral-env/defaults.yaml
regional_cluster:
  enable_bastion: true
  node_instance_families: ["m7i"]

management_cluster_defaults:
  enable_bastion: true
  node_instance_families: ["m7i"]
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

Enable write access to SRE tools (Grafana, ArgoCD):

```yaml
# .ephemeral-env/defaults.yaml
regional_cluster:
  enable_write_sre_tools: true
```

```yaml
# .ephemeral-env/us-east-1.yaml
provision_mcs:
  mc01: {}
```

By default (`enable_write_sre_tools: false`) Grafana is provisioned with anonymous
Viewer access and ArgoCD disables the admin account with anonymous read-only access.
Setting this flag to `true` restores admin access to both. This flag can only be set
to `true` for ephemeral environments — `render.py` enforces this at render time.

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

ID           REPO                                          BRANCH                    REGION       STATE                  CREATED              API_URL                                                      RHOBS_API_URL
------------ --------------------------------------------- ------------------------- ------------ ---------------------- -------------------- ------------------------------------------------------------ ------------------------------------------------------------
6bd2d3d7     typeid/rosa-hyperfleet                 ROSAENG-143               us-east-1    ready                  2026-03-19T10:14:23Z https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod  https://abc123xyz.execute-api.us-east-1.amazonaws.com/prod

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
Resolving base credentials...
Fetching GitHub token from Secrets Manager...

ROSA HyperFleet shell

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

This resolves AWS credentials, starts a bastion ECS task if none is running, waits for the execute command agent, and drops you into an interactive shell on the bastion. From there you can run `kubectl` commands against the cluster:

```
==> Bastion task ready
    ECS cluster: eph-f16cec-regional-bastion
    Task ID:     683c1f0af6ae4e1bba3552f2c8215bd3

==> Connecting to bastion...

bash-5.2# kubectl get nodes
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-0-1-42.ec2.internal    Ready    <none>   2h    v1.31.4-eks-aeac579
```

The bastion task stays running until explicitly stopped or until the environment is torn down (teardown automatically cleans up running bastion tasks).

## Port Forwarding

Forward ports from cluster-internal services to your local machine through the bastion, without needing an interactive shell. This is useful for accessing ArgoCD and Prometheus UIs directly in your browser.

> ⚠️ _Bastion must be enabled in your environment config (`enable_bastion: true` in `defaults.yaml`). The default ephemeral preset already has it enabled._

### Interactive service selection

```bash
# Select services interactively (fzf multi-select) — Regional Cluster
make ephemeral-port-forward-rc

# Select services interactively — Management Cluster
make ephemeral-port-forward-mc

# Explicit environment selection
make ephemeral-port-forward-rc ID=6bd2d3d7
```

### Forward all services at once

```bash
# Forward all available services — Regional Cluster
make ephemeral-port-forward-rc-all

# Forward all available services — Management Cluster
make ephemeral-port-forward-mc-all
```

Available services per cluster type:

| Service      | RC  | MC  | Local address          |
| ------------ | --- | --- | ---------------------- |
| ArgoCD       | yes | yes | https://localhost:8443 |
| Prometheus   | yes | yes | http://localhost:9090  |
| Thanos Query | yes | no  | http://localhost:10902 |
| Thanos Ruler | yes | no  | http://localhost:10903 |
| Loki         | yes | no  | http://localhost:13100 |
| Alertmanager | yes | no  | http://localhost:9093  |
| Grafana      | yes | no  | http://localhost:3000  |

The command fetches the ArgoCD admin password automatically and prints it to the terminal. Port forwards remain active until you press `Ctrl+C`.

Prerequisites: `aws`, `fzf`, and `lsof` must be in `PATH`.

## Run E2E Tests

Run the end-to-end test suite against one of your development environments:

```bash
# Interactive — fzf picker for environment selection
make ephemeral-e2e

# Explicit
make ephemeral-e2e ID=6bd2d3d7
```

By default, tests are cloned from the `main` branch of `rosa-hyperfleet-api`. Use `E2E_REF` and `E2E_REPO` to run against a different branch or fork:

```bash
# Run tests from a feature branch
make ephemeral-e2e ID=6bd2d3d7 E2E_REF=my-feature-branch

# Run tests from a fork
make ephemeral-e2e ID=6bd2d3d7 E2E_REPO=https://github.com/my-fork/rosa-hyperfleet-api.git E2E_REF=my-feature-branch
```

To keep the cluster and infrastructure alive after a test run (useful for debugging failures), set `E2E_SKIP_CLEANUP`:

```bash
make ephemeral-e2e ID=6bd2d3d7 E2E_SKIP_CLEANUP=1
```

This skips both the cleanup-labeled ginkgo specs and the `DeferCleanup` safety net, so the HCP cluster, VPC, IAM, and OIDC resources survive for investigation. Remember to tear them down manually afterwards with `make ephemeral-teardown` or by re-running without the flag.

### ZOA testing

`make ephemeral-e2e` above already includes a **light ZOA smoke check** for free: if the environment has a ZOA RC Lambda URL, `ci/e2e-tests.sh` clones `rosa-hyperfleet-zoa@main` and runs `make test-e2e-smoke` from that checkout — a handful of `Label("smoke")` specs (discovery, one read TA, one write TA dry-run) from ZOA's own e2e suite, against RC and, if present, MC. Nothing to opt into — it's skipped automatically when a ZOA URL isn't available. A zoa clone/build/test failure is tracked the same way as the platform API/HCP/monitoring results in that script (doesn't abort them, but **does** fail the overall `make ephemeral-e2e` run — no special treatment). ZOA owns this test logic itself (`rosa-hyperfleet-zoa/test/e2e/`); this repo doesn't duplicate it.

For **deep** validation of every Trusted Action (including real, non-dry-run `delete_pod`/`rollout_restart` execution) use `rosa-hyperfleet-zoa`'s own suite (`test/e2e/` in that repo). This follows the exact same clone-by-ref pattern as `ephemeral-e2e` above (`E2E_REF`/`E2E_REPO`) and the CLI (`CLI_REF`/`CLI_REPO`) — no new mechanism, just `ZOA_REF`/`ZOA_REPO`:

```bash
# Zero setup — clones rosa-hyperfleet-zoa@main inside the container
make ephemeral-zoa-e2e ID=6bd2d3d7

# A branch/fork you've pushed (most common pattern for iterating on a PR)
make ephemeral-zoa-e2e \
  ID=6bd2d3d7 \
  ZOA_REF=my-feature-branch \
  ZOA_REPO=https://github.com/my-fork/rosa-hyperfleet-zoa.git

# Smoke only (~2min) — fast subset, good for infra PRs or sanity checks
make ephemeral-zoa-e2e-smoke ID=6bd2d3d7
make ephemeral-zoa-e2e-smoke ID=6bd2d3d7 ZOA_REF=my-feature-branch
```

This never touches the ZOA Lambda images actually deployed in the environment — it's purely for validating the test suite against real infrastructure. As with `ephemeral-e2e`, to test uncommitted local changes push them to a branch first; there's no local-checkout-mount option here, consistent with how `ephemeral-e2e`/`E2E_REF` work for `rosa-hyperfleet-api`.

The **smoke target** (`ephemeral-zoa-e2e-smoke`) runs the same `Label("smoke")` subset that `make ephemeral-e2e` runs automatically as part of the platform e2e. Use it for a quick ZOA health check without waiting for the full deep suite.

For the full picture (test tiers, CI wiring, image management, PR-image testing) see [`rosa-hyperfleet-zoa/docs/e2e-testing.md`](https://github.com/openshift-online/rosa-hyperfleet-zoa/blob/main/docs/e2e-testing.md).

### Credentials matrix: what's automatic vs what you set yourself

Both e2e suites (`rosa-hyperfleet-api`'s and `rosa-hyperfleet-zoa`'s) sign requests with AWS
SigV4, which needs a valid `AWS_PROFILE` in scope. Whether that's handled for you depends on
_how_ you invoke the suite, not which suite it is:

| How you run it                                                                          | AWS creds                                                                                                                                                                                                                                                  | What you need to pass                                                                                                                             |
| --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make ephemeral-e2e ID=...` (this repo)                                                 | Automatic — `ci/e2e-tests.sh` (which this target runs inside the container) does `export AWS_PROFILE="rrp-rc"` itself before calling `make test-e2e-api`                                                                                                   | Just `ID` (+ optional `E2E_REF`/`E2E_REPO`)                                                                                                       |
| `make ephemeral-zoa-e2e ID=...` (this repo)                                             | Automatic — `rosa-hyperfleet-zoa`'s own `test/e2e/` sets `AWS_PROFILE` per-subprocess (`rrp-rc`/`rrp-mc`, one call at a time)                                                                                                                              | Just `ID` (+ optional `ZOA_REF`/`ZOA_REPO`)                                                                                                       |
| CI (`nightly-ephemeral`, `on-demand-e2e`, `rosa-regionality-compatibility-e2e`)         | Automatic — same `ci/e2e-tests.sh` runs, with `AWS_CONFIG_FILE` pointed at the Vault-mounted `rosa-regional-platform-ephemeral-creds` secret instead of your dev-account creds; the profile _names_ (`rrp-rc`/`rrp-mc`) and the export logic are identical | Nothing — this is what Prow triggers                                                                                                              |
| `make test-e2e-api` directly, from `rosa-hyperfleet-api` (bypassing this repo entirely) | **Manual** — nobody sets `AWS_PROFILE` for you; `config.LoadDefaultConfig()` uses whatever's already in your shell                                                                                                                                         | `export AWS_PROFILE=rrp-rc` (or your own profile that can reach the target account) yourself, then `BASE_URL=<api-gateway-url> make test-e2e-api` |
| `make test-e2e` directly, from `rosa-hyperfleet-zoa` (bypassing this repo entirely)     | **Manual, but overridable** — needs `rrp-rc`/`rrp-mc` profiles reachable from your host; override the profile _names_ with `ZOA_RC_AWS_PROFILE`/`ZOA_MC_AWS_PROFILE` if yours differ                                                                       | `export ZOA_RC_API_URL=... ZOA_MC_API_URL=...` (+ have `rrp-rc`/`rrp-mc` resolvable), then `make test-e2e`                                        |

The two "directly, bypassing this repo" rows are the only cases where you're on your own —
they exist for fast iteration on the test code itself (no container, no clone-by-ref indirection),
not as the primary way to run these suites. If you're not actively editing `test/e2e-api/*.go` or
`test/e2e/*.go`, prefer the `make ephemeral-*` targets above; credentials are then never your
problem.

## Dump Environment

Collect Kubernetes diagnostic logs (`oc adm inspect`) and PostgreSQL database state from the RC and/or MC clusters in an ephemeral environment. Data is gathered by the log-collector ECS Fargate task, uploaded to S3, and downloaded locally.

For the RC, this also dumps the `kubernetes_resources` table from Aurora PostgreSQL — producing a tabular summary (`resource-summary.txt`) and per-resource JSON files under `db-state/resources/<Kind>/<name>.json`.

```bash
# Collect from both RC and all MCs
make ephemeral-dump-env

# Collect from RC only
make ephemeral-dump-env CLUSTER=rc

# Collect from MCs only
make ephemeral-dump-env CLUSTER=mc

# Explicit environment selection
make ephemeral-dump-env ID=6bd2d3d7
```

Output is written to `/tmp/<eph-prefix>-logs-<timestamp>/`. The RC output includes a `db-state/` subdirectory with the database dump. In CI, data is automatically collected on e2e test failure with `S3_ONLY=true` — results are left in S3 (to avoid publishing sensitive data) and the S3 URIs are printed for manual retrieval.

> ⚠️ _Bastion must be enabled in your environment config (`enable_bastion: true` in `defaults.yaml`). The default ephemeral preset already has it enabled._

## Resync

The ephemeral environment runs from an ephemeral-provider managed clone of your branch. If you push additional changes to your remote branch after provisioning (e.g. updating a Helm chart or Terraform module), the environment won't pick them up automatically — you need to resync so the cloned branch is updated and ArgoCD syncs the changes.

Resync also re-applies the environment config, so changes to `.ephemeral-env/` are picked up alongside code changes.

```bash
# Interactive — fzf picker for environment selection
make ephemeral-resync

# Explicit
make ephemeral-resync ID=6bd2d3d7
```

## Swap Branch

Redirect a running environment to a different branch or fork without tearing it down and reprovisioning. The environment identity (and its managed CI branch) is preserved — only the source branch being tracked changes. After swapping, a resync runs automatically to apply the new branch.

```bash
# Interactive — fzf pickers for environment and branch selection
make ephemeral-swap-branch

# Explicit — swap to a branch on the same repo
make ephemeral-swap-branch ID=6bd2d3d7 NEW_BRANCH=my-other-feature

# Explicit — swap to a branch on a different fork
make ephemeral-swap-branch ID=6bd2d3d7 NEW_BRANCH=my-feature NEW_REPO=my-fork/rosa-hyperfleet
```

> ⚠️ _Ensure the new branch is pushed to the remote before swapping — the environment is built from the remote ref._

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
- [SRE UI Access — Integration](sop/sre-ui-access.md) -- accessing Grafana, ArgoCD, Prometheus, Thanos, and Loki in the integration environment
