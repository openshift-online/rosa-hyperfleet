# Zero Operator Access — Trusted Actions Implementation

**Last Updated Date**: 2026-06-08

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
profile: kube
scope: kube-api
type: read
description: List all nodes in the target cluster
timeout_seconds: 300
params:
  - name: node_selector
    required: false
    default: ""
    description: "Label selector to filter nodes"
rbac:
  cluster_scoped: true
  rules:
    - apiGroups: [""]
      resources: ["nodes"]
      verbs: ["get", "list"]
script: |
  set -euo pipefail
  SELECTOR_ARGS=()
  if [ -n "${PARAM_NODE_SELECTOR:-}" ]; then
    SELECTOR_ARGS=(-l "${PARAM_NODE_SELECTOR}")
  fi
  kubectl get nodes "${SELECTOR_ARGS[@]}" -o wide
  kubectl get nodes "${SELECTOR_ARGS[@]}" -o json > /artifacts/output.json
```

**No Job, no ConfigMap, no volumes, no image** — Platform API generates all of that.

**Parameter handling:**

- Each param becomes an environment variable in the Job: `PARAM_<UPPER_NAME>` (e.g., `PARAM_NODE_SELECTOR`)
- Platform API validates required params before dispatch
- Scripts access params via env vars

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
OWNERS=$(kubectl get pod $PARAM_POD_NAME -n $PARAM_NAMESPACE -o jsonpath='{.metadata.ownerReferences}')
if [ "$OWNERS" = "null" ] || [ -z "$OWNERS" ]; then
  echo '{"error": "Pod has no owner references, refusing to delete standalone pod"}' > /artifacts/output.json
  exit 1
fi
```

### What Platform API Generates (Per Execution)

From a minimal TA template, Platform API dynamically creates a ManifestWork containing:

1. **Role/ClusterRole** — from `rbac.rules` section
2. **RoleBinding/ClusterRoleBinding** — binding the profile SA to the role
3. **ConfigMap** — containing the entrypoint wrapper + the TA script
4. **Job** — with all boilerplate (image, volumes, env vars, resources, labels)

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
  cpu_request: "100m"
  memory_request: "128Mi"
  cpu_limit: "500m"
  memory_limit: "512Mi"
  ttl_seconds: "3600"
  execution_timeout_seconds: "1800"
  entrypoint.sh: |
    #!/bin/bash
    set -uo pipefail
    EXEC_LOG="/artifacts/execution.log"
    exec > >(tee -a "$EXEC_LOG") 2>&1

    upload_artifacts() {
      local upload_exit=${1:-$?}
      echo "[zoa] exit_code=${upload_exit}"
      echo "[zoa] completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      if [ -n "${ARTIFACT_BUCKET:-}" ]; then
        aws s3 cp "$EXEC_LOG" "s3://${ARTIFACT_BUCKET}/${RUN_ID}/execution.log" --quiet || true
        [ -f /artifacts/output.json ] && \
          aws s3 cp /artifacts/output.json "s3://${ARTIFACT_BUCKET}/${RUN_ID}/output.json" --quiet || true
      fi
    }

    echo "[zoa] execution_id=${RUN_ID} action=${ACTION_NAME} target=${CLUSTER_ID}"
    echo "[zoa] operator=${OPERATOR} profile=${PROFILE} type=${TYPE}"
    echo "[zoa] revision=${REVISION}"
    echo "[zoa] started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "---"
    /zoa/run.sh
    EXIT_CODE=$?
    upload_artifacts ${EXIT_CODE}
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

### Service Account Strategy — Privilege Profiles

A small number of **stable ServiceAccounts** based on privilege profiles:

| ServiceAccount | Pod Identity Role | Purpose |
|----------------|-------------------|---------|
| `zoa-kube-sa` | `s3:PutObject` only | Kube-API read/write TAs (kubectl commands) |
| `zoa-aws-read-sa` | Read-only AWS + `s3:PutObject` | AWS read TAs (describe, list, get) |
| `zoa-aws-write-sa` | Read-write AWS + `s3:PutObject` | AWS write TAs (modify, restart, scale) |
| `zoa-breakglass-read-sa` | Broad read AWS + `s3:PutObject` | Breakglass read operations |
| `zoa-breakglass-write-sa` | Broad write AWS + `s3:PutObject` | Breakglass write operations |

**Audit chain with stable SAs:**

| Layer | What's Recorded | Identifies |
|-------|----------------|------------|
| Platform API (DynamoDB) | `execution_id`, `operator`, `action`, `target`, `revision`, timestamp | Who requested what |
| ManifestWork + all resources | Labels: `zoa.rosa.io/execution-id`, `zoa.rosa.io/operator`, `zoa.rosa.io/action`, `zoa.rosa.io/revision` | Full traceability on every K8s resource |
| Kubernetes audit logs | SA name + pod labels | Which profile ran the pod + execution context via labels |
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
| `GET` | `/api/v0/trusted-actions/{action}` | Describe a specific TA (params, description, profile) |

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
  "profile": "kube",
  "status": "succeeded",
  "revision": "a1b2c3d",
  "created_at": "2026-06-08T12:00:00Z",
  "completed_at": "2026-06-08T12:00:12Z",
  "duration_seconds": 12,

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
  "profile": "kube",
  "scope": "kube-api",
  "type": "read",
  "description": "List all nodes in the target cluster",
  "params": [
    {"name": "node_selector", "required": false, "default": "", "description": "Label selector to filter nodes"}
  ]
}
```

### CLI Design

Maps to kubectl/oc patterns for SRE muscle memory:

| CLI Command | API Call | Description |
|-------------|----------|-------------|
| `zoa run <action> --target <cluster>` | `POST /trusted-actions/{action}/run` | Execute a TA |
| `zoa get <id>` | `GET /runs/{id}` | Metadata + output (default) |
| `zoa get <id> --output` | `GET /runs/{id}?fields=output` | Output only |
| `zoa logs <id>` | `GET /runs/{id}?fields=logs` | Execution log (all output) |
| `zoa list` | `GET /runs` | Last 20 executions |
| `zoa list --limit 50 --status failed` | `GET /runs?limit=50&status=failed` | Filtered list |
| `zoa describe <action>` | `GET /trusted-actions/{action}` | Show TA info, params |

**Key principles:**
- `get` retrieves the result (metadata + output.json); `logs` retrieves the execution trace — separate concepts, like kubectl
- Output is always JSON — no format flags needed
- `describe` shows what a TA does before running it (params, description, profile)

### Dispatch Flow

```
Operator (zoa run) → Platform API → Maestro (gRPC CreateManifestWork) → Maestro Agent → Target Cluster
                                                                                              │
                                                                                        Job executes
                                                                                              │
                                                                                   /zoa/entrypoint.sh
                                                                                     (tee → execution.log)
                                                                                              │
                                                                              ┌───────────────┼───────────────┐
                                                                              │                               │
                                                                        execution.log                   output.json
                                                                              │                               │
                                                                              └───────────────┼───────────────┘
                                                                                              │
                                                                                   S3 upload (on exit, always)
                                                                                              │
Platform API Reconciler:                                                                      │
  ← Maestro (GetManifestWork status) ← feedbackRules (Job succeeded/failed) ←────────────────┘
  → Delete ResourceBundle (on terminal status, race-safe)
  → DynamoDB (status: succeeded/failed/timed_out, duration, revision)
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
- Full audit trail across DynamoDB + S3 + K8s resources (labels on everything)
- Git revision tracked on every resource and in DynamoDB
- No infrastructure changes required when adding new TAs
- API proxies S3 content — clean consumer experience, no presigned URL leakage
- CLI follows kubectl/oc patterns — zero learning curve for SREs

### Negative

- Kubernetes audit logs show profile-level identity (e.g., `zoa-kube-sa`), not per-execution identity — correlation requires cross-referencing pod labels
- All TAs within a privilege profile share the same AWS permissions
- Custom image requires maintenance (updates, CVE patches, FIPS recertification)
- Platform API has more generation logic (builds ManifestWork programmatically vs. simple template rendering)

## Cross-Cutting Concerns

### Security:

- All SAs have minimal AWS permissions scoped to their profile
- Per-TA Roles/RoleBindings enforce least-privilege at the Kubernetes API level
- S3 bucket uses KMS encryption at rest
- DynamoDB uses KMS encryption at rest
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
