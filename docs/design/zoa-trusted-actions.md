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

## Design

### Service Account Strategy — Privilege Profiles

Rather than creating a per-execution SA (which would require dynamic Pod Identity wiring) or a single shared SA (poor auditability), we use a small number of **stable ServiceAccounts** based on privilege profiles:

| ServiceAccount | Pod Identity Role | Purpose |
|----------------|-------------------|---------|
| `zoa-kube-sa` | `s3:PutObject` only | Kube-API read/write TAs (kubectl commands) |
| `zoa-aws-read-sa` | Read-only AWS + `s3:PutObject` | AWS read TAs (describe, list, get) |
| `zoa-aws-write-sa` | Read-write AWS + `s3:PutObject` | AWS write TAs (modify, restart, scale) |
| `zoa-breakglass-read-sa` | Broad read AWS + `s3:PutObject` | Breakglass read operations |
| `zoa-breakglass-write-sa` | Broad write AWS + `s3:PutObject` | Breakglass write operations |

**Key design decisions:**

- All SAs share `s3:PutObject` capability for artifact publishing (required for every TA)
- Kubernetes RBAC is handled by per-TA Roles and RoleBindings (fine-grained per execution)
- AWS authorization is handled by Pod Identity on the stable SA (coarse-grained per profile)
- The TA template selects which SA to use via a `profile` field in metadata

**Audit chain with stable SAs:**

| Layer | What's Recorded | Identifies |
|-------|----------------|------------|
| Platform API (DynamoDB) | `execution_id`, `operator`, `action`, `target`, timestamp | Who requested what |
| ManifestWork metadata | Labels: `zoa.rosa.io/execution-id`, `zoa.rosa.io/operator`, `zoa.rosa.io/action` | What was dispatched |
| Kubernetes audit logs | SA name + pod labels | Which profile ran the pod |
| S3 object metadata | `x-amz-meta-execution-id`, `x-amz-meta-operator` | Output ownership |

### Artifact Handling — Platform-Injected Wrapper

TA authors write simple scripts that output to `/artifacts/`. The platform handles all boilerplate:

**What the platform injects into every Job:**

1. **Volumes**: `emptyDir` mounted at `/artifacts` and `/zoa`
2. **Init container**: Copies `/zoa/entrypoint.sh` wrapper into the shared volume
3. **Environment variables**: `RUN_ID`, `CLUSTER_ID`, `ARTIFACT_BUCKET`, `ACTION_NAME`
4. **Modified command**: Wraps the TA script with the entrypoint that captures stdout/stderr and uploads to S3

**Entrypoint wrapper (`/zoa/entrypoint.sh`):**

```bash
#!/bin/bash
set -euo pipefail

# Run the actual TA script, capturing stdout and stderr
/zoa/run.sh > /artifacts/stdout.log 2> /artifacts/stderr.log
EXIT_CODE=$?

# Upload artifacts to S3
aws s3 cp /artifacts/stdout.log "s3://${ARTIFACT_BUCKET}/${RUN_ID}/stdout.log"
aws s3 cp /artifacts/stderr.log "s3://${ARTIFACT_BUCKET}/${RUN_ID}/stderr.log"

# Upload output.json if the script produced one
if [ -f /artifacts/output.json ]; then
  aws s3 cp /artifacts/output.json "s3://${ARTIFACT_BUCKET}/${RUN_ID}/output.json"
fi

exit $EXIT_CODE
```

**TA author experience:**

```bash
#!/bin/bash
# get_nodes — List all nodes in the cluster
kubectl get nodes -o json > /artifacts/output.json
```

The author does not need to think about S3, logging, or metadata.

### Namespace and Infrastructure Pre-creation

Infrastructure is managed via ArgoCD (not ManifestWork):

| Cluster Type | Mechanism | What's Created |
|--------------|-----------|----------------|
| RC | ArgoCD app `zoa-infra` in `argocd/config/regional-cluster/` | Namespace `zoa-jobs`, all privilege-profile SAs, base ClusterRoles |
| MC | ArgoCD app `zoa-infra` in `argocd/config/management-cluster/` | Namespace `zoa-jobs`, all privilege-profile SAs, base ClusterRoles |

ManifestWork is used **only** as transport for TA executions (Job + per-execution Role/RoleBinding).

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

**Reference**: The `openshift/managed-scripts` Dockerfile (`quay.io/app-sre/managed-scripts`) uses a similar multi-stage build pattern with UBI8. We adopt the same approach with UBI9 for FIPS compliance on EKS.

**Image location**: `quay.io/redhat-rosa/zoa-tools:<version>` (to be created)

### Dispatch Flow

```
Operator → Platform API → Maestro (gRPC CreateManifestWork) → Maestro Agent → Target Cluster
                                                                                    │
                                                                              Job executes
                                                                                    │
                                                                              /zoa/entrypoint.sh
                                                                                    │
                                                                    ┌───────────────┼───────────────┐
                                                                    │               │               │
                                                              stdout.log    stderr.log    output.json
                                                                    │               │               │
                                                                    └───────────────┼───────────────┘
                                                                                    │
                                                                              S3 upload
                                                                                    │
Platform API ← Maestro (GetManifestWork status) ← feedbackRules (Job status only) ←─┘
      │
DynamoDB (status: succeeded/failed, output_path)
```

### TA Template Format

Each TA is defined in a YAML file with metadata and Kubernetes manifests:

```yaml
name: get_nodes
profile: kube
scope: kube-api
type: read
description: List all nodes in the target cluster
params:
  - name: node_selector
    required: false
    default: ""
manifests:
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: zoa-get-nodes-{{ .ExecID }}
    rules:
      - apiGroups: [""]
        resources: ["nodes"]
        verbs: ["get", "list"]
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: zoa-get-nodes-{{ .ExecID }}
    subjects:
      - kind: ServiceAccount
        name: zoa-kube-sa
        namespace: zoa-jobs
    roleRef:
      kind: ClusterRole
      name: zoa-get-nodes-{{ .ExecID }}
      apiGroup: rbac.authorization.k8s.io
  - apiVersion: batch/v1
    kind: Job
    metadata:
      name: zoa-get-nodes-{{ .ExecID }}
      namespace: zoa-jobs
      labels:
        zoa.rosa.io/execution-id: "{{ .ExecID }}"
        zoa.rosa.io/action: "{{ .ActionName }}"
    spec:
      ttlSecondsAfterFinished: 3600
      backoffLimit: 0
      template:
        metadata:
          labels:
            zoa.rosa.io/execution-id: "{{ .ExecID }}"
            zoa.rosa.io/action: "{{ .ActionName }}"
        spec:
          serviceAccountName: zoa-kube-sa
          restartPolicy: Never
          containers:
            - name: ta
              image: "{{ .Image }}"
              command: ["/zoa/entrypoint.sh"]
              env:
                - name: RUN_ID
                  value: "{{ .ExecID }}"
                - name: CLUSTER_ID
                  value: "{{ .TargetCluster }}"
                - name: ARTIFACT_BUCKET
                  value: "{{ .OutputBucket }}"
                - name: ACTION_NAME
                  value: "{{ .ActionName }}"
              volumeMounts:
                - name: artifacts
                  mountPath: /artifacts
                - name: zoa
                  mountPath: /zoa
          initContainers:
            - name: init-wrapper
              image: "{{ .Image }}"
              command: ["sh", "-c", "cp /opt/zoa/* /zoa/"]
              volumeMounts:
                - name: zoa
                  mountPath: /zoa
          volumes:
            - name: artifacts
              emptyDir: {}
            - name: zoa
              emptyDir: {}
```

## Alternatives Considered

1. **Per-execution ServiceAccount with dynamic Pod Identity**: Each TA execution creates its own SA and wires Pod Identity dynamically. Rejected because EKS Pod Identity requires Terraform/API calls per SA (cannot be done from within a ManifestWork), adding minutes of latency and significant IAM complexity.

2. **Single shared ServiceAccount**: One SA (`zoa-job-runner`) for all TAs. Rejected because Kubernetes audit logs only show SA identity — all TAs would be indistinguishable at the K8s audit level.

3. **IRSA (IAM Roles for Service Accounts)**: Allows per-SA roles via annotations. Rejected because IRSA is not fully supported in EKS Auto Mode and is being deprecated in favor of Pod Identity.

4. **Sidecar container for S3 upload**: A separate container watches `/artifacts` and uploads. Rejected in favor of a simpler wrapper approach — sidecars add complexity around container ordering and completion detection.

## Design Rationale

- **Justification**: The privilege-profile model (5 stable SAs) balances auditability, operational simplicity, and Pod Identity constraints. Each SA maps to a clear permission boundary, and per-TA Roles/RoleBindings provide fine-grained Kubernetes RBAC without requiring dynamic IAM changes.
- **Evidence**: ARO-HCP uses a similar pattern with Maestro for ManifestWork dispatch. The `openshift/managed-scripts` project validates the "swiss knife image + script" pattern at scale for OSD/ROSA operations.
- **Comparison**: Per-execution SAs offer perfect K8s audit granularity but require infrastructure changes per execution. Stable SAs trade some K8s audit granularity (profile-level, not execution-level) for zero infrastructure overhead per execution. The DynamoDB audit trail compensates by providing full execution-level traceability.

## Consequences

### Positive

- TA authors write simple scripts without boilerplate (S3, logging, metadata handled by platform)
- Scales to hundreds of TAs with only 5 IAM roles total
- Namespace and SA pre-creation via ArgoCD follows established patterns
- Full audit trail across DynamoDB + S3 + K8s audit logs
- No infrastructure changes required when adding new TAs

### Negative

- Kubernetes audit logs show profile-level identity (e.g., `zoa-kube-sa`), not per-execution identity — correlation requires cross-referencing with DynamoDB via pod labels
- All TAs within a privilege profile share the same AWS permissions — a misbehaving TA could theoretically use AWS permissions intended for another TA in the same profile
- Custom image requires maintenance (updates, CVE patches, FIPS recertification)

## Cross-Cutting Concerns

### Security:

- All SAs have minimal AWS permissions scoped to their profile
- Per-TA Roles/RoleBindings enforce least-privilege at the Kubernetes API level
- S3 bucket uses KMS encryption at rest
- DynamoDB uses KMS encryption at rest
- Jobs run with `runAsNonRoot: true` and `readOnlyRootFilesystem` where possible
- TTL-based cleanup ensures ephemeral resources don't accumulate

### Reliability:

- **Scalability**: Stable SAs and ArgoCD-managed infra support thousands of concurrent executions
- **Observability**: DynamoDB provides queryable execution history; S3 stores all outputs; ManifestWork status provides real-time job state
- **Resiliency**: Failed jobs are recorded with exit code and stderr; reconciler polls for status updates

### Cost:

- DynamoDB on-demand pricing (~$1.25/million writes)
- S3 Standard with lifecycle policy (365-day retention for FedRAMP)
- 5 Pod Identity associations per cluster (negligible)
- One custom container image build pipeline

### Operability:

- Adding a new TA: create YAML file in `ta-templates/`, push, ArgoCD syncs ConfigMap
- Adding a new privilege profile: update Terraform (IAM role + Pod Identity), ArgoCD (SA), and Platform API (profile mapping)
- Debugging: `zoa status <id>` → DynamoDB metadata + ManifestWork status + S3 outputs

---

## Related Documentation

- [ZOA Framework (Sections 1-9)](https://redhat.atlassian.net/browse/ROSA-672) — Approved layered model and access matrix
- [Maestro MQTT Resource Distribution](./maestro-mqtt-resource-distribution.md) — How ManifestWorks are dispatched
- [openshift/managed-scripts](https://github.com/openshift/managed-scripts) — Reference for script execution pattern and job image
