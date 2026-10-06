# ci/ephemeral-provider

Python package for provisioning, resyncing, and tearing down ephemeral CI environments for ROSA HyperFleet.

For local development usage via Make targets, see [Provisioning a Development Environment](../../docs/development-environment.md).

## Credentials

The `--creds-dir` directory (default: `/var/run/rosa-credentials/`) must contain:

| File           | Purpose                              | Fallback                             |
| -------------- | ------------------------------------ | ------------------------------------ |
| `github_token` | GitHub token for pushing CI branches | `HYPERFLEET_CI_GITHUB_TOKEN` env var |

The provider also expects AWS CLI profiles `rrp-central`, `rrp-rc`, and `rrp-mc` to be available via `AWS_CONFIG_FILE`. See the [AWS Profiles](../README.md#aws-profiles) section in the CI README for details.

## Direct Usage

```bash
# Requires uv (https://docs.astral.sh/uv/)

# Provision (generates a random ID and prints it — pass it to teardown/resync)
./ci/ephemeral-provider/main.py --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Provision with an explicit ID (use directly in prefix, no hashing)
./ci/ephemeral-provider/main.py --id abc123 --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Teardown (same --id)
./ci/ephemeral-provider/main.py --teardown --id abc123 --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Resync (rebase ephemeral branch onto latest source branch, same --id)
./ci/ephemeral-provider/main.py --resync --id abc123 --repo owner/repo --branch my-feature --creds-dir /path/to/credentials
```

## Overrides

Two mechanisms let you customize an ephemeral environment at provision time:

### `--override-dir`

Replaces the entire `config/ephemeral/` directory with a local directory of YAML files. Use this to swap the region, change cluster sizing, or provide a fully custom environment config. Re-applied on `--resync` so config changes are picked up alongside code changes.

```bash
./ci/ephemeral-provider/main.py --override-dir ./my-overrides/ ...
```

Also settable via `EPHEMERAL_OVERRIDE_DIR` env var.

### `--provision-override-file`

Deep-merges a YAML fragment into a specific file in the repo before the ephemeral branch is committed. Useful for surgical changes like overriding a single Helm value without replacing the whole file. Only applied during provision (not resync).

```bash
./ci/ephemeral-provider/main.py \
  --provision-override-file argocd/config/regional-cluster/platform-api/values.yaml:override.yaml \
  ...
```

Can be specified multiple times. Format is `<target-path>:<override-file>` where target path is relative to the repo root. Merge rules:

- Dicts are merged recursively
- Lists of dicts are matched by `name` key (matched items are merged, unmatched are appended)
- Scalars and plain lists are replaced

## Modules

| Module              | Description                                                                  |
| ------------------- | ---------------------------------------------------------------------------- |
| `main.py`           | CLI entrypoint — parses args, runs provision, teardown, or resync            |
| `orchestrator.py`   | Top-level orchestration logic for provision and teardown workflows           |
| `aws.py`            | AWS credential management and session helpers                                |
| `git.py`            | Git operations for ephemeral branch creation, rendering, and resync (rebase) |
| `pipeline.py`       | CodeBuild pipeline monitoring (discovery, polling, status)                   |
| `codebuild_logs.py` | CloudWatch log fetching and formatting for CodeBuild projects                |
| `yaml_utils.py`     | YAML deep-merge utilities for applying provision overrides                   |
