# Zero Operator Access (ZOA) — Architecture

**Last Updated Date**: 2026-06-11

## Summary

Zero Operator Access (ZOA) is the operational access framework for ROSA HCP v2 Regional Platform. It eliminates persistent operator access to managed clusters by routing all operational tasks through mediated, auditable channels. Operators never SSH, kubectl, or assume roles into customer infrastructure — they execute pre-approved Trusted Actions via an API.

## Problem Statement

Traditional managed-service operations require operators to have standing access (kubeconfig, IAM roles, bastion hosts) to diagnose and remediate issues. This creates:

- **Unaudited access paths**: Operators can run arbitrary commands without record
- **Persistent credentials**: Long-lived kubeconfigs and IAM roles expand the attack surface
- **No accountability**: Shared credentials obscure who did what and when
- **Compliance gaps**: FedRAMP requires complete audit trails for privileged operations

ZOA eliminates all of these by making every operational action:

- Pre-defined (approved via PR)
- Mediated (routed through the Platform API)
- Auditable (recorded in DynamoDB with full caller identity)
- Time-bounded (ephemeral, auto-cleaned)
- Least-privileged (scoped RBAC per execution)

## System Components

### Component Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            Regional Cluster (RC)                                  │
│                                                                                  │
│  ┌──────────────┐     ┌───────────────────┐     ┌──────────────────┐            │
│  │  API Gateway  │────▶│  Platform API     │────▶│  Maestro Server  │            │
│  │  (SigV4 auth) │     │  (ZOA handlers)   │     │  (gRPC + MQTT)   │            │
│  └──────────────┘     │                   │     └────────┬─────────┘            │
│                        │  ┌─────────────┐  │              │                      │
│                        │  │ Reconciler   │  │              │ MQTT                 │
│                        │  │ (5s loop)    │  │              │                      │
│                        │  └─────────────┘  │              │                      │
│                        │                   │              │                      │
│                        │  ┌─────────────┐  │              │                      │
│                        │  │ DynamoDB     │  │              │                      │
│                        │  │ (executions) │  │              │                      │
│                        │  └─────────────┘  │              │                      │
│                        │                   │              │                      │
│                        │  ┌─────────────┐  │              │                      │
│                        │  │ S3 Bucket    │  │              │                      │
│                        │  │ (artifacts)  │  │              │                      │
│                        │  └─────────────┘  │              │                      │
│                        └───────────────────┘              │                      │
└───────────────────────────────────────────────────────────┼──────────────────────┘
                                                            │
                                                            │ MQTT (no direct network)
                                                            │
┌───────────────────────────────────────────────────────────┼──────────────────────┐
│                        Management Cluster (MC)             │                      │
│                                                            ▼                      │
│                                                  ┌──────────────────┐            │
│                                                  │  Maestro Agent    │            │
│                                                  │  (applies MW)     │            │
│                                                  └────────┬─────────┘            │
│                                                           │                      │
│                         Namespace: zoa-jobs                │                      │
│                        ┌──────────────────────────────────┼──────────────┐       │
│                        │                                  ▼              │       │
│                        │  ┌─────────────────┐  ┌────────────────────┐  │       │
│                        │  │ SA (per-exec)    │  │ Runner Job          │  │       │
│                        │  │ SA (uploader)    │  │ zoa-<exec-id>       │  │       │
│                        │  └─────────────────┘  └────────────────────┘  │       │
│                        │                                                │       │
│                        │  ┌─────────────────┐  ┌────────────────────┐  │       │
│                        │  │ ConfigMap        │  │ Uploader Job        │  │       │
│                        │  │ (scripts+output) │  │ zoa-<exec-id>-up   │  │       │
│                        │  └─────────────────┘  └────────────────────┘  │       │
│                        │                                                │       │
│                        │  ┌──────────────────────────────────────────┐  │       │
│                        │  │ Role/ClusterRole (per-execution RBAC)     │  │       │
│                        │  └──────────────────────────────────────────┘  │       │
│                        └─────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Location | Role |
|-----------|----------|------|
| **API Gateway** | AWS (regional) | SigV4 authentication, request routing |
| **Platform API** | RC (EKS pod) | TA validation, job generation, dispatch, reconciliation |
| **Maestro Server** | RC (EKS pod) | ManifestWork storage, MQTT distribution |
| **Maestro Agent** | MC (EKS pod) | Applies ManifestWorks, reports status via MQTT |
| **DynamoDB** | AWS (regional) | Execution metadata, audit trail, status tracking |
| **S3** | AWS (regional) | Artifact storage (output.json, execution.log) |
| **KMS** | AWS (regional) | Encryption at rest for DynamoDB and S3 |
| **zoa-jobs namespace** | MC | Execution environment (Jobs, RBAC, ConfigMaps) |

## Request Flow — Sequence Diagram

The following diagram shows what happens for every API call, covering all component interactions:

```mermaid
sequenceDiagram
    participant Op as Operator (zoa CLI)
    participant GW as API Gateway
    participant API as Platform API
    participant DB as DynamoDB
    participant MS as Maestro Server
    participant MQTT as MQTT Broker
    participant MA as Maestro Agent
    participant MC as MC Kubernetes API
    participant Runner as Runner Job
    participant CM as ConfigMap
    participant Uploader as Uploader Job
    participant S3 as S3 Bucket

    Note over Op,S3: 1. Submission (POST /{action}/run)
    Op->>GW: POST /trusted-actions/get_pods/run (SigV4)
    GW->>GW: Validate SigV4, extract caller identity
    GW->>API: Forward request + X-Amz headers
    API->>API: Validate params, build ManifestWork
    API->>DB: Create execution record (status=pending)
    API->>MS: gRPC CreateManifestWork
    API-->>Op: 202 {id, status: "pending"}

    Note over Op,S3: 2. Dispatch (MQTT, no direct network)
    MS->>MQTT: Publish ManifestWork to MC topic
    MQTT->>MA: Deliver ManifestWork
    MA->>MC: Apply manifests (SA, RBAC, CMs, Jobs)
    MA->>MQTT: Report "Applied" status
    MQTT->>MS: Status feedback

    Note over Op,S3: 3. Execution (Two-Job model on MC)
    MC->>Runner: Start runner Job (per-exec SA)
    MC->>Uploader: Start uploader Job (static SA)
    Runner->>Runner: Execute /zoa/run.sh
    Runner->>CM: Patch output ConfigMap (base64 log + output)
    Runner->>Runner: Exit
    Uploader->>Uploader: kubectl wait for runner
    Uploader->>CM: Read output ConfigMap
    Uploader->>Uploader: Decode base64 → files
    Uploader->>S3: aws s3 cp (execution.log + output.json)
    Uploader->>Uploader: Exit

    Note over Op,S3: 4. Reconciliation (5s loop)
    API->>MS: gRPC GetManifestWork (poll feedback)
    MS-->>API: feedbackRules: succeeded/failed + Job timestamps
    API->>MS: gRPC DeleteManifestWork (cleanup)
    MA->>MC: Delete all ZOA resources from MC
    API->>DB: Update: status, runner_seconds, upload_seconds, duration_seconds, output_status

    Note over Op,S3: 5. Retrieval
    Op->>GW: GET /runs/{id}?fields=output (SigV4)
    GW->>API: Forward
    API->>DB: Get execution metadata
    API->>S3: GetObject (output.json + execution.log)
    API-->>Op: {metadata + output + logs}
```

### Per-Endpoint Data Flow Summary

| Endpoint | Components Touched |
|----------|-------------------|
| `POST /{action}/run` | API Gateway → Platform API → DynamoDB → Maestro → MQTT → Agent → MC |
| `GET /runs/{id}` | API Gateway → Platform API → DynamoDB + S3 |
| `GET /runs` | API Gateway → Platform API → DynamoDB |
| `GET /` (catalog) | API Gateway → Platform API (in-memory registry) |
| `GET /{action}` (describe) | API Gateway → Platform API (in-memory registry) |

## Network Architecture

### Key Constraint: No Direct Network Path from RC to MC

The Regional Cluster cannot reach the Management Cluster's Kubernetes API directly. All communication flows through Maestro's MQTT-based protocol:

```
RC → Maestro Server (gRPC) → MQTT Broker → Maestro Agent (MC) → MC Kubernetes API
```

This means:

- Platform API cannot kubectl into the MC
- Status feedback flows back the same path: MC → MQTT → Maestro Server → Platform API (gRPC)
- Output must be uploaded to S3 directly from the MC (the RC cannot pull it)

### Authentication Flow

```
Operator Terminal
  │
  │ eval "$(aws configure export-credentials --format env --profile rrp-dev-eph-rc)"
  │
  ▼
curl/zoa CLI
  │
  │ SigV4 signature (AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY + AWS_SESSION_TOKEN)
  │
  ▼
API Gateway (us-east-1)
  │
  │ Validates SigV4, extracts caller identity (Account ID + ARN)
  │ Passes identity via X-Amz-* headers
  │
  ▼
Platform API
  │
  │ Reads: Account ID, Caller ARN, Operator name (from session name in ARN)
  │ Records in DynamoDB: full caller identity with every execution
  │
  ▼
Maestro (gRPC CreateManifestWork)
  │
  │ No additional auth — internal service call within RC
  │
  ▼
MQTT → Maestro Agent → Job on MC
```

### S3 Output Pipeline (Two-Job Architecture)

```
Runner Job (on MC)
  │
  │ SA: zoa-runner-<exec-id> (per-execution, no S3 access)
  │ Writes output to ConfigMap: zoa-output-<exec-id>
  │
  ▼
Uploader Job (on MC)
  │
  │ SA: zoa-uploader → IAM Role (S3 PutObject + KMS Encrypt)
  │ Waits for runner job to complete
  │ Reads output from ConfigMap
  │ aws s3 cp output.json s3://<bucket>/<exec-id>/output.json
  │ aws s3 cp execution.log s3://<bucket>/<exec-id>/execution.log
  │
  ▼
S3 Bucket (regional, SSE-KMS encrypted)
  │
  │ Lifecycle: Standard → Intelligent-Tiering (30d) → Expire (365d)
  │
  ▼
Platform API (on RC)
  │
  │ Pod Identity: platform-api role → IAM (S3 GetObject + KMS Decrypt)
  │ Proxies content to consumers (no presigned URLs exposed)
  │
  ▼
Operator (via GET /runs/{id}?fields=output)
```

## Execution Flow (End-to-End)

### 1. Submission

```
Operator: zoa run get_pods -t mc-useast1-1 -n maestro
         │
         ▼
Platform API receives POST /api/v0/trusted-actions/get_pods/run
  - Validates SigV4 identity
  - Loads TA template from registry (ConfigMap)
  - Validates params (namespace required for get_pods)
  - Derives runner SA from scope + type (kube-api → per-exec SA)
  - Generates execution UUID
  - Creates DynamoDB record (status: pending, output_status: pending)
  - Builds ManifestWork (SA, RBAC, output CM, scripts CM, runner Job, upload Job)
  - Dispatches via Maestro gRPC CreateManifestWork
  - Returns {id, status: "pending"} to caller
```

### 2. Dispatch

```
Maestro Server
  - Stores ResourceBundle in database
  - Publishes to MQTT topic for target MC consumer
         │
         ▼ MQTT
         │
Maestro Agent (on MC)
  - Receives ManifestWork via MQTT subscription
  - Applies all manifests to MC Kubernetes API:
    1. ServiceAccount: zoa-runner-<exec-id> (per-execution)
    2. ClusterRole/Role (per-execution RBAC)
    3. ClusterRoleBinding/RoleBinding → runner SA
    4. ConfigMap: zoa-output-<exec-id> (empty, for output transfer)
    5. Role/RoleBinding: output CM patch permission for runner SA
    6. ConfigMap: zoa-scripts-<exec-id> (entrypoint.sh + run.sh)
    7. Runner Job: zoa-<exec-id> (executes TA, writes to output CM)
    8. Uploader Job: zoa-<exec-id>-upload (reads CM, uploads to S3)
  - Reports status back via MQTT (Applied, Available)
```

### 3. Execution (Two-Job Model)

```
Kubernetes Job Controller (on MC) — starts BOTH Jobs in parallel:

Runner Job (zoa-<exec-id>):
  - SA: zoa-runner-<exec-id> (per-execution, Kubernetes-only permissions)
  - Image: quay.io/slopezz/zoa-tools:latest
  /zoa/entrypoint.sh
    │
    ├── Logs metadata: [zoa] execution_id=... action=... target=...
    ├── Executes /zoa/run.sh (the TA script)
    │     └── kubectl get pods -n maestro -o json > /artifacts/output.json
    ├── Captures exit code
    ├── Patches ConfigMap zoa-output-<exec-id> with:
    │     - data.output.json (if exists)
    │     - data.execution.log
    │     - data.exit-code
    └── Exits with TA script's exit code

Uploader Job (zoa-<exec-id>-upload):
  - SA: zoa-uploader (static, S3 PutObject + KMS Encrypt only)
  - Image: quay.io/slopezz/zoa-tools:latest
  /zoa/upload_entrypoint.sh
    │
    ├── kubectl wait --for=condition=complete job/zoa-<exec-id> (or failed)
    ├── Reads ConfigMap zoa-output-<exec-id>
    ├── Uploads execution.log to S3 (always)
    ├── Uploads output.json to S3 (if present in CM)
    └── Exits 0 on success, 1 on upload failure
```

### 4. Reconciliation

```
Platform API Reconciler (5-second loop on RC)
  │
  ├── Queries DynamoDB: status-index WHERE status IN (pending, running)
  │
  ├── For each pending/running execution:
  │     │
  │     ├── Calls Maestro gRPC GetManifestWork
  │     │
  │     ├── Parses feedbackRules from BOTH Jobs:
  │     │     Runner:   .status.succeeded, .status.failed, .status.startTime, .status.completionTime
  │     │     Uploader: .status.succeeded, .status.failed, .status.completionTime
  │     │
  │     ├── On Applied condition (pending → running):
  │     │     └── UpdateStatus in DynamoDB
  │     │
  │     ├── On full completion (both Jobs done):
  │     │     ├── Compute durations from Job timestamps:
  │     │     │     runner_seconds  = runner.completionTime - runner.startTime
  │     │     │     upload_seconds  = uploader.completionTime - runner.completionTime
  │     │     │     duration_seconds = now - created_at (total wall-clock)
  │     │     ├── Delete ResourceBundle from Maestro (gRPC)
  │     │     │     └── Cascades: Agent removes ManifestWork → all resources on MC
  │     │     └── Update DynamoDB: status, completed_at, runner_seconds, upload_seconds,
  │     │                          duration_seconds, output_status (uploaded|failed)
  │     │
  │     └── On timeout (exceeded per-TA or global timeout):
  │           ├── Delete ResourceBundle from Maestro (cleanup first)
  │           └── Update DynamoDB: status=timed_out, duration_seconds
  │
  └── Sleep 5s → repeat
```

### 5. Retrieval

```
Operator: zoa get <exec-id>
         │
         ▼
Platform API receives GET /api/v0/trusted-actions/runs/<exec-id>?fields=output
  - Reads DynamoDB for execution metadata
  - Reads output_path (full S3 URI from DynamoDB)
  - Fetches s3://<bucket>/<exec-id>/output.json
  - Returns combined response: metadata + output JSON
         │
         ▼
Operator sees structured output (pipeable to jq)
```

## Infrastructure

### DynamoDB Table

```
Table: <env>-regional-zoa-executions
  PK: executionId (String)

GSI: account-index
  PK: accountId (String)
  SK: createdAt (String, RFC3339)
  Projection: ALL

GSI: status-index
  PK: status (String)
  SK: createdAt (String, RFC3339)
  Projection: ALL
```

### S3 Bucket

```
Bucket: <env>-regional-zoa-outputs-<account-id>
  Encryption: SSE-KMS (dedicated ZOA key)
  Versioning: Enabled
  Lifecycle:
    - Transition to Intelligent-Tiering: 30 days
    - Expiration: 365 days (FedRAMP retention)
    - Noncurrent version expiration: 30 days
    - Abort incomplete multipart: 7 days
```

### IAM Roles (Pod Identity)

| Role | Associated SA | Permissions |
|------|---------------|-------------|
| `<env>-zoa-uploader-role` | `zoa-uploader` (MC) | `s3:PutObject` on ZOA bucket + `kms:GenerateDataKey`, `kms:Encrypt` |
| `<env>-zoa-aws-read-role` | `zoa-aws-read` (MC) | AWS read actions (DescribeInstances, etc.) — no S3/KMS on ZOA bucket |
| `<env>-zoa-aws-write-role` | `zoa-aws-write` (MC) | AWS write actions — no S3/KMS on ZOA bucket |
| `<env>-platform-api-role` | `platform-api` (RC) | `s3:GetObject` on ZOA bucket + `kms:Decrypt` + `dynamodb:*` on ZOA table |

**Key design principle**: Runner SAs (`zoa-runner-<exec-id>`, `zoa-aws-read`, `zoa-aws-write`) have **zero** access to the ZOA S3 bucket. Only `zoa-uploader` can write to S3, ensuring SA isolation between operational actions and output transport.

### Terraform Module

```
terraform/modules/zoa/
  ├── dynamodb.tf       # Executions table + GSIs
  ├── s3.tf             # Output bucket + lifecycle + encryption
  ├── kms.tf            # Dedicated KMS key
  ├── iam.tf            # Job role + Platform API policy attachments
  ├── variables.tf      # Environment prefix, retention, billing mode
  └── outputs.tf        # Table name, bucket name, KMS ARN (consumed by bootstrap)
```

## TA Template System

### How TAs Are Loaded

```
TA YAML files (in platform repo or future separate repo)
  │
  ▼ (Helm template packs them into ConfigMap)
ConfigMap: zoa-ta-templates (mounted into Platform API pod at /templates/)
  │
  ▼ (Platform API reads on startup)
TemplateRegistry (in-memory map of action_name → TATemplate struct)
  │
  ▼ (On each execution request)
BuildManifestWork(template, renderContext) → ManifestWork with all K8s manifests
```

### Template → ManifestWork Generation

What the TA author writes (~15 lines):

```yaml
name: get_pods
scope: kube-api
type: read
params: [...]
rbac:
  rules: [...]
script: |
  kubectl get pods ...
```

What Platform API generates (full ManifestWork with ~200 lines of K8s manifests):

- ServiceAccount (per-execution `zoa-runner-<exec-id>`)
- Role/ClusterRole (from `rbac.rules`)
- RoleBinding/ClusterRoleBinding (SA → Role)
- Output ConfigMap (`zoa-output-<exec-id>`)
- RBAC for runner SA to patch the output ConfigMap
- Script ConfigMap (entrypoint.sh wrapper + run.sh from `script`)
- Runner Job (executes TA script, writes output to ConfigMap)
- Uploader Job (reads ConfigMap, uploads to S3)
- Job (image, volumes, env vars, resources, labels, TTL)
- ManifestWork feedbackRules (extract Job status)

### Job Boilerplate (Centrally Managed)

The Job "frame" is NOT defined by TA authors. It comes from `zoa-job-config` ConfigMap:

| Config | Default | Purpose |
|--------|---------|---------|
| `image` | `quay.io/slopezz/zoa-tools:latest` | Container image |
| `cpu_request` | `100m` | Pod CPU request |
| `memory_request` | `128Mi` | Pod memory request |
| `cpu_limit` | `500m` | Pod CPU limit |
| `memory_limit` | `512Mi` | Pod memory limit |
| `ttl_seconds` | `3600` | K8s TTL after job completion (safety GC) |
| `execution_timeout_seconds` | `1800` | Global timeout for reconciler |
| `entrypoint.sh` | (wrapper script) | Logging, S3 upload, exit handling |

Changing any of these updates ALL future TA executions — no per-TA changes needed.

## Cleanup and Lifecycle

### Normal Cleanup (Reconciler-Driven)

```
1. Reconciler detects Job terminal status (succeeded/failed) via ManifestWork feedback
2. Reconciler deletes ResourceBundle from Maestro (gRPC)
3. Maestro Agent removes ManifestWork from its local state
4. Agent cascades deletion: Job, Pod, ConfigMap, Role, RoleBinding — all removed from MC
5. Reconciler updates DynamoDB with terminal status and duration
```

### Timeout Cleanup

```
1. Reconciler detects execution exceeds timeout_seconds (per-TA) or execution_timeout_seconds (global)
2. Reconciler deletes ResourceBundle FIRST (stops the running Job)
3. Reconciler updates DynamoDB: status=timed_out, duration
```

### Safety Net (TTL)

Jobs have `ttlSecondsAfterFinished: 3600`. If reconciler cleanup fails, Kubernetes TTL controller garbage-collects the completed Job after 1 hour. This is a backup — normal cleanup happens in seconds via the reconciler.

### What Persists After Cleanup

| What | Where | Retention |
|------|-------|-----------|
| Execution metadata | DynamoDB | Indefinite (audit) |
| output.json | S3 | 365 days |
| execution.log | S3 | 365 days |
| K8s resources (Job, RBAC, CM) | MC | Deleted on completion |

## Audit Trail

Every execution produces audit data at multiple layers:

| Layer | What's Recorded | Query Method |
|-------|----------------|--------------|
| Platform API (DynamoDB) | execution_id, operator, caller_arn, action, target, status, duration, revision | `zoa runs` CLI or direct API |
| S3 (artifacts) | Full execution log, structured output | `zoa logs <id>` or `zoa get <id>` |
| Kubernetes (labels on all resources) | execution-id, operator, action, scope, type, revision, target | `kubectl get jobs -l zoa.rosa.io/operator=slopezma` |
| AWS CloudTrail | SigV4 caller identity on API Gateway invocation | CloudTrail console |
| Maestro (MQTT events) | ManifestWork create/delete events with metadata | Maestro server logs |

### Correlation

Given an execution ID, you can trace the full chain:

```
DynamoDB: execution metadata + timing
  → S3: full execution log + structured output
  → MC (while running): kubectl get jobs -l zoa.rosa.io/execution-id=<id>
  → CloudTrail: API Gateway access log for the POST request
```

## Future Considerations

### Per-Execution SA (Alternative Security Model)

See [ZOA Security Model](./zoa-security-model.md) for a detailed comparison of the current shared-SA model vs. a per-execution dynamic SA model with parallel uploader Jobs.

### TA Repository Separation

TAs will move to their own Git repository:

- Platform repo references a specific commit hash of the TA repo
- Hash is promoted between environments (dev → staging → prod)
- Allows independent release cycles for TA definitions vs. platform infrastructure
- Platform API just reads from a mounted directory — source is transparent

### Breakglass API

A future `/api/v0/breakglass/` endpoint will provide escalated access patterns:

- Requires additional approval workflow (not just SigV4 auth)
- Different CLI verb: `zoa breakglass ...` (deliberately more typing)
- Uses elevated static ServiceAccounts (`breakglass-read-sa`, `breakglass-write-sa`)
- Stricter audit requirements and time limits

### Authorization and Approval Workflow

Currently any authenticated caller can execute any TA. Future work:

- Permission model: which operators can run which TAs on which targets
- Approval workflow: write TAs require peer approval before dispatch
- Time-limited grants: temporary elevation with auto-expiry

---

## Related Documentation

- [ZOA Trusted Actions — Implementation Details](./zoa-trusted-actions.md) — TA template format, CLI design, API endpoints
- [ZOA Security Model](./zoa-security-model.md) — SA isolation strategies, RBAC model, audit
- [Maestro MQTT Resource Distribution](./maestro-mqtt-resource-distribution.md) — ManifestWork dispatch mechanism
