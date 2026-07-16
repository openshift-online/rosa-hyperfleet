# FIPS-Only Compute for EKS Clusters

**Last Updated Date**: 2026-07-08

## Summary

All EKS clusters in the ROSA HyperFleet use OSS Karpenter v1 with a FIPS-validated
`EC2NodeClass` (`fips`) and a cluster-type-specific `NodePool` for platform and application
workloads. A dedicated `karpenter-bootstrap` managed node group (t3.medium, 2 nodes, tainted
`CriticalAddonsOnly`) provides stable capacity for Karpenter itself, CoreDNS, and metrics-server.
All other workloads land on Karpenter-provisioned nodes using FIPS Bottlerocket AMIs.

## Context

FedRAMP High/Moderate authorization requires that all cryptographic operations use FIPS 140-2 or
FIPS 140-3 validated modules. On EKS, this means workload compute must run a FIPS-validated
operating system — specifically Bottlerocket with FIPS mode enabled.

- **Problem Statement**: EKS Auto Mode's built-in node pools (`system` and `general-purpose`)
  provision standard (non-FIPS) Bottlerocket AMIs and cannot be patched to use a custom
  `EC2NodeClass`. AWS auto-reverts any modifications to built-in pools within minutes. The
  bootstrap deadlock caused by disabling all pools (`node_pools = []`) and repeated
  `UnauthorizedNodeRole` failures with the embedded Karpenter made Auto Mode operationally
  fragile for FIPS requirements.
- **Constraints**:
  - EKS nodes providing FIPS-validated compute must run Bottlerocket with `advancedSecurity.fips: true`
  - The cluster bootstrap runs inside an ECS Fargate task in a private subnet with no public
    cluster API access. See [ECS Fargate Bootstrap for Fully Private EKS Clusters](./fully-private-eks-bootstrap.md).
  - Karpenter controller must run on stable, pre-provisioned nodes — it cannot schedule itself
- **Assumptions**: All clusters run OSS Karpenter (`enable_karpenter = true`, the default). EKS
  Auto Mode is disabled.

## Alternatives Considered

1. **EKS Auto Mode with `system` pool + custom FIPS NodePool**: Retains the built-in `system` pool
   for CoreDNS and metrics-server (non-FIPS, AWS-managed), adds a custom FIPS NodePool for
   workloads. Partially FIPS-compliant but requires the embedded Karpenter's bootstrap ordering
   constraints. Replaced because Auto Mode's embedded Karpenter cannot be independently upgraded
   and the `node_role_arn` / `InstanceProfileReady` sequencing caused repeated bootstrap failures.

2. **Disable all Auto Mode pools (`node_pools = []`)**: All nodes from custom FIPS NodePools.
   Creates a bootstrap deadlock: the FIPS `EC2NodeClass` `InstanceProfileReady` condition is
   evaluated only at creation time. If `node_role_arn` is absent at cluster creation, the
   NodeClass is permanently stuck with `UnauthorizedNodeRole`. Operationally fragile. Rejected.

3. **Keep EKS Auto Mode, patch built-in pools**: AWS auto-reverts user modifications to built-in
   pools. Not durable. Rejected.

4. **OSS Karpenter with dedicated bootstrap node group**: Provides a stable, pre-provisioned node
   group (tainted `CriticalAddonsOnly`) for Karpenter controller, CoreDNS, and metrics-server.
   Karpenter provisions all other nodes on demand using FIPS `EC2NodeClass`. Fully
   FIPS-compliant for customer-bearing workloads. **Chosen.**

## Design Rationale

- **Justification**: The `karpenter-bootstrap` managed node group (t3.medium, 2 nodes,
  `CriticalAddonsOnly` taint) provides stable, pre-provisioned capacity for Karpenter itself and
  EKS system addons. This eliminates the bootstrap chicken-and-egg problem: Karpenter is installed
  first (on the bootstrap node group), then the FIPS `EC2NodeClass` and `NodePool` are applied,
  then a prewarm pod validates EC2 provisioning before ArgoCD is installed.

- **Evidence**: The prewarm step in the ECS bootstrap task explicitly provisions one Karpenter node
  and waits up to 8 minutes for it to become Ready before proceeding to ArgoCD installation. This
  surfaces EC2 API rate limiting and IAM role sequencing issues as early ECS task failures
  (retried automatically by ECS) rather than silent cascades post-ArgoCD.

- **Tradeoff**: The `karpenter-bootstrap` node group runs non-FIPS standard Amazon Linux 2023 (AL2023) nodes.
  These nodes host only Karpenter controller, CoreDNS, and metrics-server — EKS system
  infrastructure, not customer-bearing workloads. Platform and application workloads run
  exclusively on FIPS Karpenter-provisioned nodes. This scope boundary is an accepted tradeoff
  for operational reliability.

## Consequences

### Positive

- Platform and application workloads run on Bottlerocket with FIPS-validated cryptographic
  modules, satisfying FedRAMP High/Moderate cryptographic requirements for customer-bearing
  compute.
- Bootstrap is reliable: the bootstrap node group provisions nodes immediately, Karpenter installs
  cleanly, and the prewarm pod validates EC2 provisioning before ArgoCD is involved.
- OSS Karpenter can be independently upgraded via Helm without waiting for AWS EKS Auto Mode
  support cycles.
- The FIPS `EC2NodeClass` and `NodePool` are applied by the ECS bootstrap task and subsequently
  adopted by ArgoCD on first sync, making them GitOps-managed.

### Negative

- Karpenter controller, CoreDNS, and metrics-server run on non-FIPS t3.medium nodes. These are
  AWS-managed system addons, not customer-bearing workloads, but they are not FIPS-validated.
- Two IAM roles are required: `karpenter-node-role` (for Karpenter-provisioned nodes) and a
  lightweight role for the `karpenter-bootstrap` node group (not used directly by workloads).

## Cross-Cutting Concerns

### Reliability

- **Scalability**: The FIPS `NodePool` handles all platform and application workloads. Karpenter
  scales reactively on pending pods using EC2 instance provisioning.
- **Observability**: Karpenter NodeClaims are visible via `kubectl get nodeclaims`. CloudWatch
  logs for the ECS bootstrap task provide a full audit trail including the prewarm validation.
- **Resiliency**: The `karpenter-bootstrap` node group is a fixed-size managed node group (2
  nodes); AWS manages availability. Karpenter nodes are ephemeral and replaced automatically.

### Security

- Platform and application workload nodes run with `advancedSecurity.fips: true` and
  `kernelLockdown: Integrity`, satisfying FIPS 140-2/140-3 requirements for SC-13.
- The FIPS `EC2NodeClass` selects subnets and security groups via cluster-owned tags, ensuring
  nodes land in the correct private subnets with correct network policies.
- Karpenter controller IAM role uses IRSA (ServiceAccount annotation on `kube-system/karpenter`)
  with least-privilege SQS, EC2, and IAM instance profile permissions.
- Karpenter node IAM role (`${cluster_id}-karpenter-node-role`) is referenced directly in the
  `EC2NodeClass`, scoping node permissions to a cluster-specific role.

### Performance

- FIPS-mode Bottlerocket has negligible performance overhead for general-purpose workloads.
- `consolidateAfter: 60s` on the workloads `NodePool` enables rapid scale-down of idle capacity.

### Cost

- The `karpenter-bootstrap` node group (2x t3.medium) runs continuously. Karpenter workload nodes
  are on-demand EC2 instances provisioned reactively.
- `WhenEmpty` consolidation reclaims idle Karpenter capacity promptly, reducing EC2 spend.

### Operability

- The FIPS `EC2NodeClass` and `NodePool` are created by the ECS bootstrap task on first run and
  subsequently managed by ArgoCD. Day-2 changes are made via GitOps — no manual `kubectl apply`.
- Adding a new cluster type requires adding an `eks-nodepool` Helm chart entry for the new
  `cluster_type`, which the bootstrap task selects via the `CLUSTER_TYPE` environment variable.
- EC2 interruption events (spot reclamation, instance retirement) are handled by Karpenter via
  an SQS queue wired to EventBridge rules provisioned by the `eks-cluster` module.
