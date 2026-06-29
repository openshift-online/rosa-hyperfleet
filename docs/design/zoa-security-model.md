# Zero Operator Access (ZOA) — Security Model

**Last Updated Date**: 2026-06-14

## Summary

This document details the security architecture for ZOA Trusted Actions: how privileges are scoped, how isolation is enforced between executions, how audit trails are constructed, and what alternatives were evaluated for ServiceAccount isolation.

## Threat Model

### Threats Mitigated

| Threat                                           | Mitigation                                                                                                                     |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| Operator runs arbitrary commands on clusters     | Only pre-defined TAs can be executed — no shell access, no kubectl proxy                                                       |
| Operator accesses secrets/data beyond their need | Per-execution RBAC limits access to exactly what the TA declares                                                               |
| Operator acts without attribution                | Every execution records caller identity (ARN, account, operator name) and required Jira ticket                                 |
| Compromised TA escalates privileges              | TA script runs with scoped Role, cannot self-modify SA or create privileged resources                                          |
| Rapid repeated write actions                     | Write cooldown (global 300s default, per-TA override) with `force` bypass; `force` flag recorded in execution record for audit |
| Target cluster overload                          | Max concurrent per target (default 10 running + pending; dry-run and force excluded); `force` flag recorded for audit          |
| Stale credentials persist                        | No long-lived kubeconfigs — all access is ephemeral (Job exits → resources deleted)                                            |
| S3 output exfiltrated                            | Bucket is encrypted (SSE-KMS), no presigned URLs exposed, API proxies content                                                  |
| Log tampering                                    | S3 versioning enabled, lifecycle prevents deletion before 365 days                                                             |

### Trust Boundaries

```mermaid
flowchart TB
    A["Trust Zone A: Operator Workstation\n- SigV4 credentials (STS, time-limited)\n- Cannot reach MC/RC directly"]
    B["Trust Zone B: Regional Cluster (RC)\n- Platform API (validates, dispatches)\n- Maestro Server (stores, distributes)\n- DynamoDB + S3 (persists)"]
    C["Trust Zone C: Management Cluster (MC)\n- Maestro Agent (applies manifests)\n- zoa-jobs namespace (executes TAs)\n- Control plane namespaces (HCPs)"]

    A -->|"HTTPS + SigV4"| B
    B -->|"MQTT (encrypted)"| C
```

The ZOA system operates at the boundary between Zone B and Zone C. Platform API (Zone B) generates RBAC but cannot enforce it — the Kubernetes API server on the target cluster (Zone B or C) enforces RBAC at runtime.

## Identity and Authentication

### Caller Identity Chain

```
AWS STS → Temporary Credentials → SigV4 Signature → API Gateway → Platform API
```

Platform API extracts from the SigV4-authenticated request:

| Field        | Source                       | Example                                                     |
| ------------ | ---------------------------- | ----------------------------------------------------------- |
| `account_id` | API Gateway context          | `123456789012`                                              |
| `caller_arn` | API Gateway context          | `arn:aws:sts::123456789012:assumed-role/DevAccess/slopezma` |
| `operator`   | Parsed from ARN session name | `slopezma`                                                  |

These are recorded with every execution — no way to execute a TA without identity.

### Authorization and Approval

All current TAs declare `authorization.approval: none`. Executions record `approval_state: not_required` in DynamoDB; audit entries carry the same field. The approval lifecycle supports future gated TAs:

| State          | Meaning                                               |
| -------------- | ----------------------------------------------------- |
| `not_required` | TA policy does not require approval (all current TAs) |
| `pending`      | Approval required but not yet obtained                |
| `approved`     | Required approvals obtained; execution authorized     |
| `rejected`     | Approval explicitly denied                            |

### No Shared Credentials

- Operators use their own AWS credentials (not a shared service account)
- Credentials are STS temporary tokens with configurable session duration
- API Gateway validates the signature cryptographically — no token forwarding

## RBAC Model

### Per-Execution RBAC (Dynamic)

Every TA execution creates its own Role/ClusterRole + Binding on the target cluster:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: zoa-<execution-id>
  namespace: maestro
  labels:
    zoa.rosa.io/execution-id: "fa65418c-..."
    zoa.rosa.io/action: "get_pods"
    zoa.rosa.io/managed: "true"
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: zoa-<execution-id>
  namespace: maestro
subjects:
  - kind: ServiceAccount
    name: zoa-runner-<execution-id>
    namespace: zoa-jobs
roleRef:
  kind: Role
  name: zoa-<execution-id>
```

**Key properties:**

- RBAC resources are scoped to exactly what the TA declares — nothing more
- RoleBindings bind the per-execution runner SA
- All RBAC resources are deleted when the reconciler cleans up the ResourceBundle
- Namespace-scoped Roles for namespace-specific TAs, ClusterRoles for cluster-wide TAs

### ServiceAccount Model (Two-Job Architecture)

ZOA uses a split SA model for privilege separation:

| SA                     | Lifecycle               | Kubernetes Access                                    | AWS Access                                |
| ---------------------- | ----------------------- | ---------------------------------------------------- | ----------------------------------------- |
| `zoa-runner-<exec-id>` | Per-execution (dynamic) | Per-execution Role only                              | **None**                                  |
| `zoa-uploader`         | Static (infra)          | Per-execution Role (dynamic, `resourceNames`-scoped) | `s3:PutObject` + `kms:Encrypt`            |
| `zoa-aws-read`         | Static (infra)          | Per-execution Role                                   | AWS read-only APIs (no S3 on ZOA bucket)  |
| `zoa-aws-write`        | Static (infra)          | Per-execution Role                                   | AWS read-write APIs (no S3 on ZOA bucket) |

**Key design decisions:**

1. **Per-execution SA for kube TAs**: `zoa-runner-<exec-id>` is created dynamically as part of the ManifestWork. It has no Pod Identity (no AWS IAM role). This gives perfect K8s audit-log attribution.
2. **Static SAs for AWS TAs**: `zoa-aws-read` and `zoa-aws-write` require pre-provisioned Pod Identity associations. These are static but still have **no access to the ZOA S3 bucket**.
3. **Dedicated uploader SA**: Only `zoa-uploader` can write to S3. Kubernetes RBAC for the uploader is generated dynamically per execution (not a static Helm template), scoped with `resourceNames` to the specific output ConfigMap and runner Job.
4. **No SA has both**: No single SA has both operational permissions AND S3 write access.

## Secrets Protection

### Multi-Layer Defense

ZOA has multiple safeguards preventing Trusted Actions from accessing Kubernetes Secrets:

#### Layer 1: TA Template RBAC (Compile-Time)

TA authors declare exactly which resources they need. The `get_secrets` TA would need:

```yaml
rbac:
  rules:
    - apiGroups: [""]
      resources: ["secrets"]
      verbs: ["get", "list"]
```

This is visible in code review. Any new TA or RBAC change requires PR approval.

#### Layer 2: Platform API Validation (Runtime)

Platform API enforces runtime constraints before dispatch:

- **Implemented**: Rejects any TA requesting `secrets` access in HCP namespaces (`clusters-*` prefix) — `validateSecretsPolicy` in jobbuilder
- **Planned**: Require elevated approval for sensitive resources
- **Planned**: Additional namespace deny-listing beyond HCP namespaces

#### Layer 3: Runner SA Isolation (Two-Job Architecture)

Even if a Role grants `secrets` access, the runner SA has no AWS credentials at all:

- `zoa-runner-<exec-id>` has zero AWS IAM permissions — it cannot exfiltrate to any AWS destination
- Only `zoa-uploader` has S3 access, and it only reads from the output ConfigMap (not from the cluster)
- NetworkPolicy (planned) will further restrict egress from `zoa-jobs` namespace

#### Layer 4: Audit and Detection

Any attempt to access secrets would be:

- Recorded in Kubernetes audit logs (SA + pod labels identify the execution)
- Correlated to the operator via DynamoDB execution record
- Queryable via `zoa audit` for post-incident investigation

## S3 Output Security

### Encryption

- **At rest**: SSE-KMS with a dedicated ZOA KMS key
- **In transit**: HTTPS (TLS 1.2+ enforced by bucket policy)
- **Key policy**: Only the ZOA job role and Platform API role can use the key

### Access Control

```
Bucket Policy:
  - Principal: zoa-job-role → Action: s3:PutObject (write only, no read/delete)
  - Principal: platform-api-role → Action: s3:GetObject (read only, no write/delete)
  - Deny all other principals
  - Deny non-TLS connections (aws:SecureTransport=false)
```

### No Direct Consumer Access

The API proxies S3 content — consumers never receive presigned URLs or direct bucket access. This means:

- No URL sharing/leakage risk
- Access is always authenticated and logged
- Platform API can enforce additional authorization checks

### Object Metadata for Audit

Every S3 object carries metadata headers:

```
x-amz-meta-execution-id: fa65418c-...
x-amz-meta-operator: slopezma
x-amz-meta-action: get_pods
x-amz-meta-target: mc-useast1-1
```

## Audit Trail Completeness

### What's Recorded Where

| Event                         | Storage                  | Retention              | Query           |
| ----------------------------- | ------------------------ | ---------------------- | --------------- |
| TA execution requested        | DynamoDB (executions)    | 365 days (TTL)         | `zoa runs`      |
| Full execution log            | S3                       | 365 days               | `zoa logs <id>` |
| Structured output             | S3                       | 365 days               | `zoa get <id>`  |
| Jira ticket correlation       | DynamoDB (`jira` field)  | 365 days (TTL)         | `zoa get <id>`  |
| All API calls (POST + GET)    | DynamoDB (audit table)   | 365 days (TTL)         | `zoa audit`     |
| API Gateway access            | CloudTrail               | 90 days (configurable) | AWS Console     |
| Kubernetes API calls from Job | Target cluster audit log | Cluster-dependent      | kubectl audit   |
| ResourceBundle lifecycle      | Maestro server logs      | Log retention          | kubectl logs    |

**Audit table design**: Every audited call (`POST /run`, `GET /runs`, `GET /runs/{id}`, `GET /audit`) is recorded with consistent fields: `id`, `account_id`, `caller_arn`, `operator`, `method`, `path` (full URI), `action`, `target_cluster`, `execution_id`, `jira`, `approval_state`, `status_code`, `timestamp`. Fields not applicable to a call type are empty strings. The sort key uses nanosecond-precision timestamps (`2006-01-02T15:04:05.000000000Z`) for uniqueness. Catalog/describe endpoints are not audited (public metadata, high frequency).

### Correlation Keys

All layers use `execution-id` as the primary correlation key:

```
CloudTrail → API Gateway request with execution-id in response
DynamoDB → execution record with full metadata
S3 → objects keyed by execution-id
Target cluster K8s resources → labels with zoa.rosa.io/execution-id
Target cluster audit logs → SA + pod labels map to execution-id
```

### Immutability

- DynamoDB: No `DeleteItem` permissions for Platform API role (update-only); records auto-expire via TTL after 365 days
- S3: Versioning enabled, lifecycle prevents deletion before 365 days
- K8s audit logs: Cluster-level, not modifiable by workloads

## Two-Job Architecture

### Design Goals

The two-job architecture enforces privilege separation:

1. **SA isolation**: Runner SAs carry only Kubernetes RBAC permissions — no AWS credentials for S3
2. **Reduced blast radius**: A compromised TA script cannot exfiltrate to S3
3. **K8s audit attribution**: Per-execution SAs (`zoa-runner-<exec-id>`) identify exactly which execution performed each K8s action
4. **Separation of concerns**: Operational actions (runner) and output transport (uploader) are distinct

### Architecture

```
ManifestWork contains:
  ├── ServiceAccount: zoa-runner-<exec-id> (per-execution, no AWS)
  ├── Role/ClusterRole (per-execution RBAC for TA)
  ├── RoleBinding → zoa-runner-<exec-id>
  ├── ConfigMap: zoa-output-<exec-id> (empty, output transfer)
  ├── Role: zoa-output-<exec-id> (allows runner to patch output CM)
  ├── RoleBinding → zoa-runner-<exec-id>
  ├── ConfigMap: zoa-scripts-<exec-id> (entrypoint.sh + run.sh)
  │
  ├── Role: zoa-uploader-<exec-id> (dynamic, resourceNames-scoped)
  ├── RoleBinding → zoa-uploader (static SA)
  │
  ├── Runner Job: zoa-<exec-id>
  │     ServiceAccount: zoa-runner-<exec-id> (dynamic, no Pod Identity)
  │     Volumes: scripts ConfigMap, EmptyDir (/artifacts)
  │     On completion: patches output ConfigMap with results
  │
  └── Uploader Job: zoa-<exec-id>-upload
        ServiceAccount: zoa-uploader (static, Pod Identity: s3:PutObject only)
        Waits for runner Job to complete, reads output CM, uploads to S3
```

### Properties

| Aspect                           | Value                                                                                        |
| -------------------------------- | -------------------------------------------------------------------------------------------- |
| **SA for TA script**             | `zoa-runner-<exec-id>` (per-execution, no AWS creds)                                         |
| **SA for S3 upload**             | `zoa-uploader` (static, Pod Identity, per-execution K8s RBAC via `resourceNames`)            |
| **AWS creds in TA Job**          | No — dynamic SA has no Pod Identity                                                          |
| **K8s audit attribution**        | Per-execution (e.g., `zoa-runner-fa65418c`)                                                  |
| **Resource count per execution** | ~11 (SA, TA RBAC, output CM, output RBAC, uploader RBAC, scripts CM, runner Job, upload Job) |
| **Output size limit**            | 1MB (ConfigMap limit for inter-job transfer)                                                 |
| **Latency overhead**             | +3-10s (uploader waits for runner completion + S3 upload)                                    |
| **IAM associations**             | Pod Identity per target cluster (RC + each MC, static, pre-provisioned via Terraform)        |

### Known Constraints

**1MB ConfigMap limit**: Output transferred via ConfigMap is limited to ~1MB. For all current read TAs (get_pods, get_nodes, etc.) output is well under this. If larger output is needed in the future, alternatives include:

- Shared PVC between Jobs (eliminates size limit but adds provisioning)
- Runner direct S3 upload for specific large-output TAs (breaks isolation but pragmatic)

**Uploader RBAC is dynamic per execution**: Platform API generates a `Role`/`RoleBinding` pair (`zoa-uploader-<exec-id>`) in each ManifestWork, scoped with `resourceNames` to:

- The specific output ConfigMap (`zoa-output-<exec-id>`)
- The specific runner Job (`zoa-<exec-id>`)

The `zoa-uploader` ServiceAccount is static (required for Pod Identity), but its Kubernetes permissions are least-privilege per execution.

**Uploader SA is static**: All upload operations share one SA (`zoa-uploader`). This is acceptable because:

- S3 uploads are write-only (no read access to existing artifacts)
- The execution ID in the S3 key path provides attribution
- DynamoDB records which execution produced which output

## FIPS Compliance

| Component      | FIPS Control                                          |
| -------------- | ----------------------------------------------------- |
| S3 encryption  | SSE-KMS with FIPS-validated KMS endpoint              |
| TLS            | FIPS-validated TLS libraries in RHEL UBI9 base image  |
| AWS CLI in job | Uses FIPS endpoints when `AWS_USE_FIPS_ENDPOINT=true` |
| DynamoDB       | FIPS endpoint via VPC Gateway Endpoint                |
| MQTT (Maestro) | TLS 1.2+ with FIPS-validated cipher suites            |

## Network Security (Planned)

### zoa-jobs Namespace Policies

> **Status**: Not yet deployed. The following NetworkPolicy is planned for a future iteration to restrict TA Job egress.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: zoa-jobs-egress
  namespace: zoa-jobs
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    # Allow: Kubernetes API (for kubectl commands)
    - to:
        - ipBlock: { cidr: <kube-api-cidr>/32 }
      ports:
        - port: 443
          protocol: TCP
    # Allow: S3 and KMS via VPC endpoints
    - to:
        - ipBlock: { cidr: <vpc-endpoint-cidr> }
      ports:
        - port: 443
          protocol: TCP
    # Allow: DNS
    - to: []
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

**When deployed, denied by default:**

- No internet egress (no arbitrary HTTP calls from TA scripts)
- No lateral movement to other namespaces
- No access to node metadata service (IMDS blocked)

## Summary of Controls

| NIST Control                              | ZOA Implementation                                                                                                                                                                                       |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AC-2 (Account Management)                 | STS temporary credentials, no shared accounts                                                                                                                                                            |
| AC-3 (Access Enforcement)                 | Per-execution RBAC, per-execution SA, SigV4 auth                                                                                                                                                         |
| AC-6 (Least Privilege)                    | RBAC scoped to declared resources only                                                                                                                                                                   |
| AU-2 (Audit Events)                       | DynamoDB records all executions + separate audit table records all API calls                                                                                                                             |
| AU-3 (Content of Audit Records)           | Executions: operator, jira, action, target, approval_state, timestamp, duration, status, dry_run, force. Audit: method, path (full URI), action, target, execution_id, jira, approval_state, status_code |
| AU-9 (Protection of Audit Info)           | S3 versioning, no-delete lifecycle, KMS encryption, DynamoDB TTL (365d)                                                                                                                                  |
| AU-12 (Audit Generation)                  | Automatic — all audited API calls recorded; rejections (400/429) also captured                                                                                                                           |
| CM-7 (Least Functionality)                | No shell access, no arbitrary commands — only pre-approved TAs                                                                                                                                           |
| IA-2 (Identification and Authentication)  | SigV4 + STS, caller ARN extracted per request                                                                                                                                                            |
| SC-8 (Transmission Confidentiality)       | TLS 1.2+ on all channels (API, MQTT, S3)                                                                                                                                                                 |
| SC-13 (Cryptographic Protection)          | FIPS-validated KMS, SSE-KMS at rest                                                                                                                                                                      |
| SC-28 (Protection of Information at Rest) | SSE-KMS for S3 and DynamoDB                                                                                                                                                                              |
| SI-4 (Information System Monitoring)      | Reconciler loop monitors execution status continuously                                                                                                                                                   |

---

## Related Documentation

- [ZOA Architecture](./zoa-architecture.md) — Full system architecture and component interactions
- [ZOA Trusted Actions](./zoa-trusted-actions.md) — TA template format, CLI design, API details
