# Zero Operator Access — Trusted Actions Implementation

**Last Updated Date**: 2026-06-12

## Summary

Zero Operator Access (ZOA) Trusted Actions provide a mediated, auditable mechanism for executing predefined operational tasks on ROSA HCP v2 regional infrastructure without granting operators direct cluster access. All actions are dispatched via Maestro as ManifestWorks, executed as ephemeral Kubernetes Jobs, and produce artifacts stored in S3 with full audit trails in DynamoDB.

## Context

- **Problem Statement**: Operators currently require direct kubectl/AWS CLI access to diagnose and remediate cluster issues. This violates Zero Operator Access principles by creating persistent, unaudited access paths. We need a system that allows operational tasks to be executed exclusively through predefined, auditable channels.
- **Constraints**:
  - EKS Pod Identity allows only one IAM role per ServiceAccount per namespace
  - Maestro ManifestWork is the only transport mechanism from RC to MC (no direct network path)
  - ManifestWork `feedbackRules` status values are size-limited (~1KB per field, 128KB total via MQTT)
  - All output must be stored in S3 (not in ManifestWork status)
  - Must be FIPS-compliant for FedRAMP
- **Assumptions**:
  - Maestro Agent runs on both RC and MC clusters
  - Platform API is the single entry point for TA execution
  - ArgoCD manages infrastructure provisioning on both cluster types
  - TAs may move to their own repository in the future

## Design

### Separation of Concerns

| Concern | Owner | Where |
|---------|-------|-------|
| Script logic + RBAC rules | TA author | `trusted-actions/` directory (ConfigMap, future: separate repo) |
| Job boilerplate (image, volumes, entrypoint, resources) | Platform/infra team | `zoa-job-config` ConfigMap in platform repo |
| Job generation logic | Platform API code | Go code reads template + config, builds ManifestWork |
| Infrastructure (namespace, SAs, Pod Identity) | Platform/infra team | `zoa-infra` ArgoCD app + Terraform |

### TA Template Format (What Authors Write)

Each TA is a minimal YAML file — just metadata, RBAC rules, parameters, and script:

```yaml
name: get_nodes
scope: kube-api
type: read
description: List or get nodes in the target cluster
timeout_seconds: 300
approval_required: false
params:
  - name: name
    required: false
    default: ""
    description: "Specific node name (omit to list all)"
  - name: node_selector
    required: false
    default: ""
    description: "Label selector to filter nodes"
  - name: verbose
    required: false
    default: "false"
    description: "Return full JSON output instead of compact summary"
rbac:
  cluster_scoped: true
  rules:
    - apiGroups: [""]
      resources: ["nodes"]
      verbs: ["get", "list"]
script: |
  set -euo pipefail
  NAME_ARGS=()
  if [ -n "${PARAM_NAME:-}" ]; then
    NAME_ARGS=("${PARAM_NAME}")
  fi
  SELECTOR_ARGS=()
  if [ -n "${PARAM_NODE_SELECTOR:-}" ]; then
    SELECTOR_ARGS=(-l "${PARAM_NODE_SELECTOR}")
  fi
  kubectl get nodes ${NAME_ARGS[@]+"${NAME_ARGS[@]}"} ${SELECTOR_ARGS[@]+"${SELECTOR_ARGS[@]}"} -o json > /tmp/raw.json
  if jq -e '.kind | endswith("List")' /tmp/raw.json > /dev/null 2>&1; then
    cp /tmp/raw.json /tmp/list.json
  else
    jq '{items: [.]}' /tmp/raw.json > /tmp/list.json
  fi
  cp /tmp/list.json /artifacts/output.json
```

**Optional template fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `approval_required` | `false` | Exposed in Describe API; future approval workflow integration (not enforced yet) |
| `write_cooldown_seconds` | `0` (uses global default) | Per-TA write cooldown override |
| `dry_run_action` | `""` | Read TA to execute when `dry_run: true` is set (write TAs only) |

**No Job, no ConfigMap, no volumes, no image** — Platform API generates all of that.

**Parameter handling:**

- Each param becomes an environment variable in the Job: `PARAM_<UPPER_NAME>` (e.g., `PARAM_NODE_SELECTOR`)
- Platform API validates required params before dispatch
- Scripts access params via env vars
- All `get_*` read TAs accept an optional `name` parameter to fetch a single resource; response is normalized to list format (single item in array). Cannot be combined with `all_namespaces=true`. Cluster-scoped resources (`get_nodes`, `get_namespaces`, `get_pvs`) also support `name`
- Write TAs use a standardized `name` parameter (e.g. `rollout_restart`, `delete_pod`)

**Timeout:**

- Each TA can specify `timeout_seconds` (optional) for a per-action timeout override
- Global default is set via `execution_timeout_seconds` in `zoa-job-config` ConfigMap (default: 1800s / 30 min)
- Read TAs typically use 300s (5 min); write TAs 600s (10 min)

**Output convention:**

- Scripts MUST write structured output to `/artifacts/output.json` (JSON format, machine-parseable)
- All output (stdout + stderr interleaved) is captured to `execution.log` via `tee` in the entrypoint
- The entrypoint uploads `execution.log` to S3 unconditionally on exit (success or failure) via a trap
- Write TAs SHOULD include `affected_resources` in output.json for audit:
  ```json
  {
    "affected_resources": [
      {"kind": "Pod", "namespace": "maestro", "name": "maestro-xyz", "action": "deleted"}
    ],
    "summary": "Pod replaced successfully, controller will recreate"
  }
  ```

**Safety checks (required for write TAs):**

Write TAs MUST validate preconditions before acting. Platform API does not have direct access to the target cluster, so validation happens within the script:

```bash
# Example: refuse to delete standalone pod (no controller to recreate it)
OWNERS=$(kubectl get pod "${PARAM_NAME}" -n "${PARAM_NAMESPACE}" -o jsonpath='{.metadata.ownerReferences}')
if [ "$OWNERS" = "null" ] || [ -z "$OWNERS" ]; then
  echo '{"error": "Pod has no owner references, refusing to delete standalone pod"}' > /artifacts/output.json
  exit 1
fi
```

### What Platform API Generates (Per Execution)

From a minimal TA template, Platform API dynamically creates a ManifestWork containing:

1. **ServiceAccount** — per-execution `zoa-runner-<exec-id>`
2. **Role/ClusterRole** — from `rbac.rules` section
3. **RoleBinding/ClusterRoleBinding** — binding the runner SA to the role
4. **Output ConfigMap** — `zoa-output-<exec-id>` for inter-job transfer
5. **Output RBAC** — allows runner SA to patch the output ConfigMap
6. **Uploader RBAC** — dynamic `Role`/`RoleBinding` (`zoa-uploader-<exec-id>`) scoped via `resourceNames`
7. **Script ConfigMap** — entrypoint wrapper + TA script
8. **Runner Job** — executes TA, writes output to ConfigMap
9. **Uploader Job** — reads ConfigMap, uploads to S3

All generated resources carry rich labels for audit tracing:

```yaml
labels:
  zoa.rosa.io/execution-id: "abc-123"
  zoa.rosa.io/action: "get_nodes"
  zoa.rosa.io/operator: "slopezma"
  zoa.rosa.io/profile: "kube"
  zoa.rosa.io/type: "read"
  zoa.rosa.io/scope: "kube-api"
  zoa.rosa.io/target-cluster: "mc-useast1-1"
  zoa.rosa.io/revision: "a1b2c3d"
  zoa.rosa.io/managed: "true"
annotations:
  zoa.rosa.io/created-at: "2026-06-08T12:00:00Z"
```

The `revision` label tracks which Git commit of the TA definition was used — stored in DynamoDB AND on every created resource.

### Job Boilerplate Configuration

Managed via a ConfigMap (`zoa-job-config`) in the platform repo, NOT hardcoded in API code:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: zoa-job-config
  namespace: platform-api
data:
  image: "quay.io/slopezz/zoa-tools:latest"
  revision: "<injected from ArgoCD git_revision>"
  cpu_request: "25m"
  memory_request: "64Mi"
  cpu_limit: "250m"
  memory_limit: "256Mi"
  ttl_seconds: "3600"
  execution_timeout_seconds: "1800"
  write_cooldown_seconds: "300"
  max_concurrent_per_target: "10"
  entrypoint.sh: |
    #!/bin/bash
    set -uo pipefail
    ts() { date -u '+%H:%M:%S'; }
    EXEC_LOG="/artifacts/execution.log"

    {
      echo "[$(ts)] runner starting"
      echo "[zoa] execution_id=${RUN_ID} action=${ACTION_NAME} target=${CLUSTER_ID}"
      echo "[zoa] operator=${OPERATOR} scope=${SCOPE} type=${TYPE}"
      echo "[zoa] revision=${REVISION}"
      echo "[zoa] started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      echo "---"
      /zoa/run.sh
    } 2>&1 | tee "$EXEC_LOG"
    EXIT_CODE=${PIPESTATUS[0]}

    {
      echo "---"
      echo "[$(ts)] exit_code=${EXIT_CODE}"
      echo "[$(ts)] patching configmap"
    } | tee -a "$EXEC_LOG"

    # Patch output ConfigMap with base64-encoded log + output for uploader
    LOG_B64=$(base64 -w0 "$EXEC_LOG")
    PATCH="{\"binaryData\":{\"execution.log\":\"${LOG_B64}\""
    [ -f /artifacts/output.json ] && PATCH="${PATCH},\"output.json\":\"$(base64 -w0 /artifacts/output.json)\""
    PATCH="${PATCH}},\"data\":{\"exit-code\":\"${EXIT_CODE}\"}}"
    kubectl patch configmap "${OUTPUT_CONFIGMAP}" -n "${JOB_NAMESPACE}" --type=merge -p "${PATCH}"
    exit ${EXIT_CODE}
```

TA authors can optionally override resources for heavy tasks:

```yaml
name: must_gather
resources:
  cpu: "1"
  memory: "2Gi"
script: |
  ...heavy script...
```

### Cleanup and Lifecycle

Cleanup is **reconciler-driven**, not purely TTL-based:

1. **On terminal status (succeeded, failed, timed_out)**: The Platform API reconciler deletes the ResourceBundle from Maestro via gRPC. Maestro Agent cascades deletion to all resources on the MC (Job, Pod, ConfigMap, RBAC).
2. **Race-safe ordering**: ResourceBundle is deleted BEFORE DynamoDB status is updated. If RB deletion fails, status stays `pending`/`running` and the reconciler retries on the next tick.
3. **TTL as safety net**: Jobs have `ttlSecondsAfterFinished: 3600` (1h) as backup GC in case reconciler fails to clean up.
4. **Logs survive cleanup**: The entrypoint uploads `execution.log` to S3 before the Job exits, so troubleshooting data is available via the API even after the Pod/Job is deleted.

**The ServiceAccount is NEVER deleted** — it's infrastructure managed by `zoa-infra`.

### Service Account Strategy — Two-Job Split

ZOA uses a split SA model separating operational permissions from output transport:

| ServiceAccount | Lifecycle | Kubernetes Access | AWS Access (Pod Identity) |
|----------------|-----------|-------------------|--------------------------|
| `zoa-runner-<exec-id>` | Per-execution (dynamic) | Per-execution Role only | **None** |
| `zoa-uploader` | Static (infra) | Per-execution Role (dynamic, `resourceNames`-scoped) | `s3:PutObject` + `kms:Encrypt` |
| `zoa-aws-read` | Static (infra) | Per-execution Role | AWS read-only APIs (no S3 on ZOA bucket) |
| `zoa-aws-write` | Static (infra) | Per-execution Role | AWS read-write APIs (no S3 on ZOA bucket) |

**Key design decisions:**

1. **Per-execution SA for kube TAs**: `zoa-runner-<exec-id>` is created dynamically in the ManifestWork. No Pod Identity — perfect K8s audit attribution.
2. **Static SAs for AWS TAs**: `zoa-aws-read` and `zoa-aws-write` require pre-provisioned Pod Identity. They have **no access to the ZOA S3 bucket**.
3. **Dedicated uploader SA**: Only `zoa-uploader` can write to S3. Uploader Kubernetes RBAC is generated dynamically per execution in the ManifestWork (the static `uploader-rbac.yaml` Helm template was removed), scoped with `resourceNames` to the specific output ConfigMap and runner Job.
4. **No SA has both**: No single SA has both operational permissions AND S3 write access.

**Audit chain:**

| Layer | What's Recorded | Identifies |
|-------|----------------|------------|
| Platform API (DynamoDB) | `execution_id`, `operator`, `jira`, `action`, `target`, `params`, `revision`, `updated_at`, `dry_run`, `force`, timestamps | Who requested what, when, why (Jira), and how (dry-run/forced) |
| ManifestWork + all resources | Labels: `zoa.rosa.io/execution-id`, `zoa.rosa.io/operator`, `zoa.rosa.io/action`, `zoa.rosa.io/revision` | Full traceability on every K8s resource |
| Kubernetes audit logs | Per-execution SA name (`zoa-runner-<exec-id>`) + pod labels | Perfect execution-level attribution |
| S3 object metadata | `x-amz-meta-execution-id`, `x-amz-meta-operator` | Output ownership |

### Namespace and Infrastructure Pre-creation

Infrastructure is managed via ArgoCD (not ManifestWork):

| Cluster Type | Mechanism | What's Created |
|--------------|-----------|----------------|
| RC | ArgoCD app `zoa-infra` in `argocd/config/shared/` | Namespace `zoa-jobs`, all privilege-profile SAs |
| MC | ArgoCD app `zoa-infra` in `argocd/config/shared/` | Namespace `zoa-jobs`, all privilege-profile SAs |

ManifestWork is used **only** as transport for TA executions (Job + per-execution RBAC + ConfigMap).

### Job Image

A custom "swiss knife" image built for ZOA jobs, based on UBI9 for FIPS compliance:

**Base**: `registry.access.redhat.com/ubi9/ubi-minimal`

**Included tools:**

| Tool | Source | Purpose |
|------|--------|---------|
| `kubectl` | OpenShift mirror | Kubernetes API operations |
| `oc` | OpenShift mirror | OpenShift-specific operations |
| `aws` | AWS CLI v2 | AWS API operations + S3 upload |
| `jq` | UBI package | JSON processing |
| `yq` | GitHub release | YAML processing |
| `python3` | UBI package | Complex scripting |
| `bash` | UBI package | Shell scripting |
| `curl` | UBI package | HTTP operations |

**Image source**: `images/zoa-tools/Dockerfile` in this repository.

**Image location**: `quay.io/slopezz/zoa-tools:latest` (development), future: `quay.io/redhat-rosa/zoa-tools:<version>`

**Reference**: The `openshift/managed-scripts` Dockerfile (`quay.io/app-sre/managed-scripts`) uses a similar pattern with UBI8.

### API Design

#### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v0/trusted-actions/{action}/run` | Execute a Trusted Action |
| `GET` | `/api/v0/trusted-actions/runs/{id}` | Get execution |
| `GET` | `/api/v0/trusted-actions/runs` | List executions (paginated) |
| `GET` | `/api/v0/trusted-actions` | List available TAs (catalog) |
| `GET` | `/api/v0/trusted-actions/{action}` | Describe a specific TA (params, description, metadata) |

#### Create Request Body

All `POST /trusted-actions/{action}/run` calls require a `jira` field:

```json
{
  "target_cluster": "mc-useast1-1",
  "jira": "ROSAENG-1234",
  "params": {"namespace": "maestro", "name": "maestro-abc-123"},
  "force": false,
  "dry_run": false
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `target_cluster` | Yes | Target management cluster |
| `jira` | Yes | Jira ticket (stored in DynamoDB, returned in execution records) |
| `params` | No | TA parameters (all values are strings) |
| `force` | No | Bypass write cooldown (default: `false`) |
| `dry_run` | No | Execute `dry_run_action` instead (default: `false`) |

#### Query Parameters for GET /runs/{id}

Uses a single `fields` parameter for selecting response content:

| Request | Returns |
|---------|---------|
| `GET /runs/{id}` | metadata + output (default) |
| `GET /runs/{id}?fields=output` | metadata + output |
| `GET /runs/{id}?fields=logs` | metadata + execution.log content |
| `GET /runs/{id}?fields=all` | metadata + output + logs |
| `GET /runs/{id}?fields=output,logs` | any combination |

The API proxies S3 content directly — no presigned URLs exposed to consumers.

#### Query Parameters for GET /runs (List)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `limit` | 20 | Number of runs to return (max 100) |
| `page` | 1 | Page number |
| `status` | — | Filter: `pending`, `running`, `succeeded`, `failed`, `timed_out` |
| `action` | — | Filter by TA name |
| `target` | — | Filter by target cluster |
| `operator` | — | Filter by who ran it |
| `scope` | — | Filter by scope: `kube-api`, `aws-api` |
| `type` | — | Filter by type: `read`, `write` |
| `output_status` | — | Filter by output status: `pending`, `uploaded`, `failed` |
| `dry_run` | — | Filter: `true` or `false` |
| `force` | — | Filter: `true` or `false` |
| `since` | — | Only runs after this timestamp |
| `sort` | `desc` | Sort by created_at |

#### Response Format

```json
{
  "id": "abc-123",
  "action": "get_nodes",
  "operator": "slopezma",
  "target_cluster": "mc-useast1-1",
  "scope": "kube-api",
  "type": "read",
  "jira": "ROSAENG-1234",
  "status": "succeeded",
  "revision": "a1b2c3d",
  "created_at": "2026-06-08T12:00:00Z",
  "updated_at": "2026-06-08T12:00:12Z",
  "completed_at": "2026-06-08T12:00:12Z",
  "duration_seconds": 12,
  "runner_seconds": 5,
  "upload_seconds": 7,

  "output": {
    "affected_resources": [...],
    "summary": "..."
  },
  "logs": "[zoa] execution_id=abc-123 action=get_nodes ...\n---\n..."
}
```

**Execution statuses:**

| Status | Meaning |
|--------|---------|
| `pending` | Execution created, ManifestWork dispatched but not yet applied |
| `running` | ManifestWork applied, Job running on target cluster |
| `succeeded` | Job completed successfully (exit 0) |
| `failed` | Job failed (non-zero exit) |
| `timed_out` | Execution exceeded per-TA or global timeout — reconciler force-cleaned |

#### List Response Format

```json
{
  "items": [...],
  "total": 142,
  "page": 1,
  "limit": 20,
  "has_more": true
}
```

#### Describe Response Format (GET /trusted-actions/{action})

```json
{
  "name": "get_nodes",
  "scope": "kube-api",
  "type": "read",
  "description": "List or get nodes in the target cluster with status and resource information",
  "approval_required": false,
  "write_cooldown_seconds": 0,
  "dry_run_action": "",
  "params": [
    {"name": "name", "required": false, "default": "", "description": "Specific node name (omit to list all)"},
    {"name": "label_selector", "required": false, "default": "", "description": "Label selector to filter nodes (e.g. node-role.kubernetes.io/worker=)"},
    {"name": "verbose", "required": false, "default": "false", "description": "Return full JSON output instead of compact summary"}
  ]
}
```

Example write TA with dry-run and cooldown:

```json
{
  "name": "rollout_restart",
  "scope": "kube-api",
  "type": "write",
  "description": "Perform a rolling restart of a deployment",
  "approval_required": false,
  "write_cooldown_seconds": 300,
  "dry_run_action": "get_deployments",
  "params": [
    {"name": "namespace", "required": true, "description": "Namespace of the deployment"},
    {"name": "name", "required": true, "description": "Name of the deployment to restart"}
  ]
}
```

### CLI Design

Designed around SRE muscle memory — mirrors `kubectl`/`oc` patterns with familiar flags.
Implementation: `hack/zoa.sh` (source in `.zshrc`).

#### Setup

```bash
# Add to .zshrc
source /path/to/rosa-regional-platform/hack/zoa.sh
export ZOA_API="https://<api-gateway-id>.execute-api.<region>.amazonaws.com/prod"
```

#### Command Structure

```
zoa <verb> [resource] [flags]
```

#### Commands

| Command | API Call | Behavior |
|---------|----------|----------|
| `zoa run <action> -t <cluster> --jira <ticket>` | POST + poll + GET output | **Synchronous** — waits, prints result |
| `zoa run <action> --no-wait` | POST only | Async — prints ID immediately |
| `zoa get <id>` | `GET /runs/{id}?fields=output` | Brief header + output content (default) |
| `zoa get <id> --logs` | `GET /runs/{id}?fields=logs` | Logs from a past run |
| `zoa get <id> --all` | `GET /runs/{id}?fields=output,logs` | Full result (output + logs) |
| `zoa get <id> --info` | `GET /runs/{id}?fields=none` | Formatted metadata summary (not raw JSON) |
| `zoa get <id> --json` | `GET /runs/{id}` | Raw JSON response |
| `zoa logs <id>` | `GET /runs/{id}?fields=logs` | Shortcut for `get --logs` |
| `zoa runs` | `GET /runs` | List recent executions (formatted table) |
| `zoa runs --json` | `GET /runs` | Raw JSON list response |
| `zoa runs -t <cluster>` | `GET /runs?target=<cluster>` | Filter by target |
| `zoa runs --status failed` | `GET /runs?status=failed` | Filter by status |
| `zoa runs --action get_pods` | `GET /runs?action=get_pods` | Filter by action |
| `zoa runs --dry-run` | `GET /runs?dry_run=true` | Filter dry-run executions only |
| `zoa runs --force` | `GET /runs?force=true` | Filter forced executions only |
| `zoa runs --since 1h` | `GET /runs?since=1h` | Filter by time |
| `zoa actions` | `GET /trusted-actions` | List available TAs (formatted table) |
| `zoa describe <action>` | `GET /trusted-actions/{action}` | Formatted TA metadata + params table |
| `zoa describe <action> --json` | `GET /trusted-actions/{action}` | Raw JSON describe response |

**ID Format**: Execution IDs are standard UUID v4 (e.g., `fa65418c-f4eb-4f5c-8314-baaeb695ba7d`).
Full UUIDs are required for `get`, `logs`, and other ID-based operations. The `✓ <id>`
confirmation on stderr shows the full UUID — copy-paste from `zoa runs` output.

#### Run Flags (mirrors kubectl)

| Flag | Param | Description |
|------|-------|-------------|
| `-t, --target <cluster>` | `target_cluster` | Target cluster (**required**) |
| `--jira <ticket>` | `jira` | Jira ticket (**required**, e.g. `ROSAENG-1234`) |
| `-n <namespace>` | `namespace` | Namespace |
| `-A` | `all_namespaces=true` | All namespaces |
| `-l <selector>` | `label_selector` | Label selector (kubectl `-l` syntax) |
| `-v, --verbose` | `verbose=true` | Full JSON output (no compact) |
| `--resource <type>` | `resource` | Resource type (for `get_resource`) |
| `--name <name>` | `name` | Resource name (read TAs: single fetch; write TAs: target resource) |
| `--force` | `force=true` | Bypass write cooldown |
| `--dry-run` | `dry_run=true` | Execute `dry_run_action` instead (preview) |
| `--no-wait` | — | Don't poll; return ID immediately |
| `--param key=value` | arbitrary | Pass any param not covered by flags |

#### Output Contract

- **stderr**: Progress/status messages (`✓`, `✗`, timing breakdown) — human feedback
- **stdout**: Pure JSON for `zoa run` output — pipeable to `jq`, scripts, or files
- **Human-readable modes**: `zoa get <id> --info`, `zoa describe <action>`, `zoa get <id>` (default), and `zoa runs` show formatted summaries; use `--json` for raw JSON

Timing display format on completion:

```
total=22s (runner=5s upload=12s dispatch=5s)
```

This means `zoa run ... | jq '...'` always works cleanly for run output.

#### Typical SRE Session

```bash
# 1. What can I do?
$ zoa actions
$ zoa describe get_pods

# 2. Run and see result immediately (synchronous — polls until done)
$ zoa run get_nodes -t eph-bc5fee45-mc01 --jira ROSAENG-1234
✓ fa65418c-f4eb-4f5c-8314-baaeb695ba7d        # full UUID (stderr)
✓ completed (total=22s (runner=5s upload=12s dispatch=5s))  # timing breakdown (stderr)
[                                             # output (stdout)
  {"name": "ip-10-0-1-15.ec2.internal", "status": "Ready", "roles": "worker", "age": "45d", ...},
  {"name": "ip-10-0-2-88.ec2.internal", "status": "Ready", "roles": "worker", "age": "45d", ...}
]

# 3. Fetch a single resource by name
$ zoa run get_pods -t eph-bc5fee45-mc01 -n maestro --name maestro-abc-123 --jira ROSAENG-1234

# 4. Pipe to jq for further filtering
$ zoa run get_pods -t eph-bc5fee45-mc01 -A --jira ROSAENG-1234 | jq '.[] | select(.restarts > 5)'
$ zoa run get_pods -t eph-bc5fee45-mc01 -A --jira ROSAENG-1234 | jq '.[] | select(.status != "Running")'

# 5. Filters
$ zoa run get_pods -t eph-bc5fee45-mc01 -n maestro -l app=maestro --jira ROSAENG-1234
$ zoa run get_pods -t eph-bc5fee45-mc01 -A --jira ROSAENG-1234
$ zoa run get_resource -t eph-bc5fee45-mc01 --resource hostedclusters -A --jira ROSAENG-1234

# 6. Write operations
$ zoa run rollout_restart -t eph-bc5fee45-mc01 -n maestro --name maestro --jira ROSAENG-1234
$ zoa run delete_pod -t eph-bc5fee45-mc01 -n maestro --name maestro-xyz --jira ROSAENG-1234

# 7. Dry-run preview before a write
$ zoa run rollout_restart -t eph-bc5fee45-mc01 -n maestro --name maestro --dry-run --jira ROSAENG-1234

# 8. Force bypass write cooldown
$ zoa run rollout_restart -t eph-bc5fee45-mc01 -n maestro --name maestro --force --jira ROSAENG-1234

# 9. On failure, logs are shown automatically (stderr)
$ zoa run get_pods -t eph-bc5fee45-mc01 -n invalid --jira ROSAENG-1234
✓ 3b7f9e21-a4c8-4d12-b567-89abcdef0123
✗ failed (total=15s (runner=3s upload=8s dispatch=4s))
ERROR: Specify namespace or set all_namespaces=true

# 10. Discover available actions and their params
$ zoa actions
$ zoa describe get_pods
$ zoa describe rollout_restart
$ zoa describe rollout_restart --json   # raw JSON

# 11. Go back and check a past run
$ zoa get fa65418c-f4eb-4f5c-8314-baaeb695ba7d            # header + output
$ zoa get fa65418c-f4eb-4f5c-8314-baaeb695ba7d --info    # formatted metadata summary
$ zoa get fa65418c-f4eb-4f5c-8314-baaeb695ba7d --info --json  # raw JSON metadata
$ zoa logs fa65418c-f4eb-4f5c-8314-baaeb695ba7d           # execution trace
$ zoa get fa65418c-f4eb-4f5c-8314-baaeb695ba7d --all      # output + logs + metadata

# 12. History — scoped to incident context (all filters combinable)
$ zoa runs -t eph-bc5fee45-mc01 --since 1h
$ zoa runs --status failed --since 24h
$ zoa runs --action get_pods --operator slopezma --since 7d
$ zoa runs --type write --since 12h
$ zoa runs --scope kube-api --status succeeded --limit 50
$ zoa runs --dry-run --since 24h
$ zoa runs --force --since 7d
$ zoa runs --action rollout_restart --target eph-bc5fee45-mc01 --json
```

#### Design Principles

- **`run` is synchronous**: Submit → poll → print output. Like `kubectl exec`, not `kubectl apply`.
  On failure, logs are printed automatically — no second command needed to see the error.
- **`--jira` is always required**: Every execution must be linked to a Jira ticket for audit.
- **`--no-wait` for background**: Long tasks (must-gather) can run async; check later with `zoa get`.
- **`get` = header + output, `get --info` = metadata, `logs` = trace**: Human-readable by default; `--json` for raw JSON.
- **`-t` is always required**: No hidden defaults — explicit target prevents wrong-cluster mistakes.
- **Flags match kubectl**: `-n`, `-A`, `-l`, `--name` behave identically to muscle-memory expectations.
- **stdout/stderr contract**: JSON on stdout for `zoa run` (pipeable), status/progress on stderr (human-only).
- **Write safety**: `--dry-run` previews via `dry_run_action`; `--force` bypasses write cooldown and max concurrent.
- **UUID v4**: IDs are standard UUID v4 (`google/uuid`). Full IDs required for lookups —
  copy-paste from `zoa runs` output.
- **Compact by default**: Read TAs return kubectl-wide-equivalent fields; pass `-v` for full objects.
- **Time-scoped history**: `--since` prevents information overload during incidents.
- **`ZOA_API` env var**: No hardcoded URLs. Set once per session/profile.
- **Bare verbs for TAs, prefixed for breakglass**: TAs are the hot path; `breakglass` is the escalation
  path and deliberately requires more typing (see breakglass section).

### Rate Limiting and Safety Controls

#### Write Cooldown

- Global default: 300s (via `write_cooldown_seconds` in `zoa-job-config` ConfigMap)
- Per-TA override: `write_cooldown_seconds` in template YAML (e.g. `delete_pod`: 60s, `rollout_restart`: 300s)
- Bypass: `force: true` in API request, `--force` in CLI
- Returns HTTP 429 with `write-cooldown` error when active
- Not enforced for dry-run requests

#### Max Concurrent Per Target

- Global default: 10 (via `max_concurrent_per_target` in `zoa-job-config` ConfigMap)
- Counts running + pending executions for the target cluster (per account)
- Dry-run executions are excluded from the check
- Bypass: `force: true` in API request, `--force` in CLI (same as write cooldown)
- Returns HTTP 429 with `max-concurrent` error when limit reached

#### Dry-Run Preview

Write TAs can specify `dry_run_action` (name of a read TA):

```yaml
name: rollout_restart
dry_run_action: get_deployments
```

When `dry_run: true` is set, Platform API executes the referenced read TA instead. The execution record stores:
- `action`: the originally requested action (e.g. `rollout_restart`)
- `executed_action`: the substituted read action (e.g. `get_deployments`)
- `dry_run: true`

CLI displays: `✓ <id> (DRY-RUN: rollout_restart → get_deployments)`

#### Force Bypass

The `force: true` flag bypasses both write cooldown and max concurrent checks:

- CLI: `--force` flag
- API: `"force": true` in request body
- The `force` flag is recorded in the execution record for audit
- Queryable: `zoa runs --force` or `GET /runs?force=true`
- CLI displays: `✓ <id> [FORCED]`

### Dispatch Flow (Two-Job Architecture)

```
Operator (zoa run) → Platform API → Maestro (gRPC CreateManifestWork) → Maestro Agent → Target Cluster
                                                                                              │
                                                                                  Applies ManifestWork:
                                                                                  SA, RBAC, ConfigMaps, Jobs
                                                                                              │
                                                                            ┌─────────────────┴────────────────────┐
                                                                            │                                      │
                                                                     Runner Job                             Uploader Job
                                                                     (per-exec SA)                          (static SA: zoa-uploader)
                                                                            │                                      │
                                                                   /zoa/entrypoint.sh                     kubectl wait (runner)
                                                                     (tee → execution.log)                         │
                                                                            │                              Read output ConfigMap
                                                                  Patch output ConfigMap                    Decode base64 → files
                                                                   (base64: log + output)                          │
                                                                            │                              aws s3 cp → S3 bucket
                                                                          Exit                                   Exit
                                                                            │                                      │
                                                                            └──────────────────┬───────────────────┘
                                                                                               │
Platform API Reconciler (5s loop):                                                             │
  ← Maestro (GetManifestWork) ← feedbackRules (succeeded/failed + Job timestamps) ←───────────┘
  → Compute: runner_seconds, upload_seconds, duration_seconds
  → Delete ResourceBundle (on terminal status, race-safe → cascades cleanup on MC)
  → DynamoDB (status, durations, output_status, revision, updated_at)
```

### TA Versioning and Future Separate Repo

- Today: TAs are stored in a directory within the platform repo, packed into a ConfigMap, mounted into Platform API
- Future: TAs move to their own repo with independent release cycle
- Platform API reads from a mounted directory — it doesn't care about the source
- Every execution records the `revision` (Git SHA) of the TA used in DynamoDB and on all K8s resources
- Platform admins control which revision is active per environment (promotion pipeline)

## Alternatives Considered

1. **Per-execution ServiceAccount with dynamic Pod Identity**: Each TA execution creates its own SA and wires Pod Identity dynamically. Rejected because EKS Pod Identity requires Terraform/API calls per SA (cannot be done from within a ManifestWork), adding minutes of latency and significant IAM complexity.

2. **Single shared ServiceAccount**: One SA (`zoa-job-runner`) for all TAs. Rejected because Kubernetes audit logs only show SA identity — all TAs would be indistinguishable at the K8s audit level.

3. **IRSA (IAM Roles for Service Accounts)**: Allows per-SA roles via annotations. Rejected because IRSA is not fully supported in EKS Auto Mode and is being deprecated in favor of Pod Identity.

4. **Sidecar container for S3 upload**: A separate container watches `/artifacts` and uploads. Rejected in favor of a simpler wrapper approach — sidecars add complexity around container ordering and completion detection.

5. **Full ManifestWork templates (Job + RBAC defined by TA author)**: TA authors define the entire ManifestWork content including Job spec. Rejected because it couples boilerplate (image, volumes, resources, entrypoint) to each TA, requiring all TAs to be updated when infrastructure changes (e.g., image bump).

## Design Rationale

- **Justification**: The privilege-profile model (5 stable SAs) balances auditability, operational simplicity, and Pod Identity constraints. Separating TA authoring (script + RBAC) from execution boilerplate (image, wrapper, resources) enables independent evolution of each concern.
- **Evidence**: ARO-HCP uses a similar pattern with Maestro for ManifestWork dispatch. The `openshift/managed-scripts` project validates the "swiss knife image + script" pattern at scale for OSD/ROSA operations.
- **Comparison**: Per-execution SAs offer perfect K8s audit granularity but require infrastructure changes per execution. Stable SAs trade some K8s audit granularity (profile-level, not execution-level) for zero infrastructure overhead per execution. Rich labels on all resources compensate by enabling correlation via kube audit logs.

## Consequences

### Positive

- TA authors write ~15 lines of YAML (name + rbac + script) — no boilerplate
- Scales to hundreds of TAs with only 5 IAM roles total
- Image, entrypoint, and resources managed centrally — single place to update
- Full audit trail across DynamoDB + S3 + K8s resources (labels on everything), including required Jira ticket
- Git revision tracked on every resource and in DynamoDB
- DynamoDB TTL auto-expires execution records after 365 days (aligned with S3 retention)
- Write cooldown and max-concurrent limits prevent accidental target overload
- Dry-run preview for write TAs via `dry_run_action`
- No infrastructure changes required when adding new TAs
- API proxies S3 content — clean consumer experience, no presigned URL leakage
- CLI follows kubectl/oc patterns — zero learning curve for SREs

### Negative

- Custom image requires maintenance (updates, CVE patches, FIPS recertification)
- Platform API has more generation logic (builds ManifestWork programmatically vs. simple template rendering)
- 1MB ConfigMap limit constrains inter-job output transfer size

## Cross-Cutting Concerns

### Security:

- All SAs have minimal AWS permissions scoped to their profile
- Per-TA Roles/RoleBindings enforce least-privilege at the Kubernetes API level
- S3 bucket uses KMS encryption at rest
- DynamoDB uses KMS encryption at rest with 365-day TTL auto-expiry
- Jobs run with `runAsNonRoot: true`
- TTL-based cleanup ensures ephemeral resources don't accumulate
- Revision tracking ensures traceability to specific TA definitions

### Reliability:

- **Scalability**: Stable SAs and ArgoCD-managed infra support thousands of concurrent executions. DynamoDB uses a `status-index` GSI for efficient reconciler queries (no full-table scans)
- **Observability**: DynamoDB provides queryable execution history; S3 stores execution logs and output; ManifestWork status provides real-time job state
- **Resiliency**: Reconciler uses race-safe ordering (delete RB before status update) to prevent stale resources. Per-TA and global timeouts prevent stuck executions. Logs are uploaded unconditionally to S3 before Job exits.
- **Timeout handling**: Executions exceeding their timeout are marked `timed_out` (distinct from `failed`), RB is deleted, and the full duration is recorded

### Cost:

- DynamoDB on-demand pricing (~$1.25/million writes)
- S3 Standard with lifecycle policy (365-day retention for FedRAMP)
- 5 Pod Identity associations per cluster (negligible)
- One custom container image build pipeline

### Operability:

- Adding a new TA: create YAML file in `trusted-actions/`, push, ArgoCD syncs ConfigMap
- Updating the image/wrapper: change `zoa-job-config` values, ArgoCD syncs, Platform API hot-reloads
- Adding a new privilege profile: update Terraform (IAM role + Pod Identity), ArgoCD (SA), and Platform API (profile mapping)
- Debugging: `zoa logs <id>` → full execution log from S3 (available even after Job/Pod GC)

---

## Related Documentation

- [ZOA Framework (Sections 1-9)](https://redhat.atlassian.net/browse/ROSA-672) — Approved layered model and access matrix
- [Maestro MQTT Resource Distribution](./maestro-mqtt-resource-distribution.md) — How ManifestWorks are dispatched
- [openshift/managed-scripts](https://github.com/openshift/managed-scripts) — Reference for script execution pattern and job image
