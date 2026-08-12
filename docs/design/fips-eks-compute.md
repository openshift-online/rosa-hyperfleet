# FIPS-Only Compute for EKS Clusters

**Last Updated Date**: 2026-07-08

## Summary

All EKS clusters in the ROSA HyperFleet use self-managed Karpenter with an `EC2NodeClass` (`fips`)
and a cluster-type-specific `NodePool` for platform and application workloads. A dedicated
`karpenter-bootstrap` managed node group (m7i.xlarge, 2 nodes, scheduled via the
`bootstrap-critical` PriorityClass) provides stable capacity for Karpenter itself, CoreDNS, and
metrics-server. All other workloads land on Karpenter-provisioned nodes.

**Note**: FIPS-validated compute (RHEL nodes with FIPS mode enabled) is planned for a future
iteration. Current implementation uses standard Bottlerocket AMIs pinned via the
`bottlerocket@v1.64.0` alias. FIPS enablement will be delivered as part of the RHEL AMI work.

## Context

FIPS-enabled RHEL nodes support FIPS 140-2/140-3 validated cryptographic modules for node-level
compute. The ROSA HyperFleet will use RHEL-based nodes with FIPS mode enabled via userData
configuration once the RHEL AMI work is complete. Node-level FIPS mode is one input to FedRAMP
High/Moderate authorization; validated cryptography across cluster and workload operations
(control plane, data in transit/at rest, application layer) requires additional controls beyond
node OS configuration.

- **Problem Statement**: EKS Auto Mode's built-in node pools (`system` and `general-purpose`)
  provision standard Bottlerocket AMIs and cannot be patched to use custom `EC2NodeClass`
  configurations. AWS auto-reverts any modifications to built-in pools within minutes. The
  bootstrap deadlock caused by disabling all pools (`node_pools = []`) and repeated
  `UnauthorizedNodeRole` failures with the embedded Karpenter made Auto Mode operationally
  fragile for custom node configurations.
- **Constraints**:
  - The cluster bootstrap runs inside an ECS Fargate task in a private subnet with no public
    cluster API access. See [ECS Fargate Bootstrap for Fully Private EKS Clusters](./fully-private-eks-bootstrap.md).
  - Karpenter controller must run on stable, pre-provisioned nodes — it cannot schedule itself
  - FIPS-validated compute requires RHEL nodes with FIPS mode enabled at boot time (planned)
- **Assumptions**: All clusters run self-managed Karpenter. EKS Auto Mode is disabled.

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

4. **Self-managed Karpenter with dedicated bootstrap node group**: Provides a stable, pre-provisioned node
   group (`bootstrap-critical` PriorityClass) for Karpenter controller, CoreDNS, and metrics-server.
   Karpenter provisions all other nodes on demand using custom `EC2NodeClass`. Enables future
   FIPS compliance for customer-bearing workloads via RHEL AMI configuration. **Chosen.**

## Design Rationale

- **Justification**: The `karpenter-bootstrap` managed node group (m7i.xlarge, 2 nodes,
  `bootstrap-critical` PriorityClass) provides stable, pre-provisioned capacity for Karpenter itself and
  EKS system addons. This eliminates the bootstrap chicken-and-egg problem: ECS bootstrap installs
  ArgoCD, then ArgoCD installs Karpenter and creates the `EC2NodeClass` and `NodePool` via GitOps
  Applications.

- **Evidence**: Karpenter and eks-nodepool sync concurrently — there is no sync-wave ordering
  between them, consistent with the project's eventual-consistency ArgoCD model (`selfHeal: true`,
  `retry.limit: -1` with exponential backoff). If eks-nodepool's apply runs before Karpenter's CRDs
  are registered, ArgoCD retries until it succeeds. The ApplicationSet injects cluster-specific
  values (clusterName, interruptionQueue, IRSA role ARN) into the Karpenter Helm chart, and the
  eks-nodepool chart creates the `EC2NodeClass` and workloads `NodePool`.

- **Tradeoff**: The `karpenter-bootstrap` node group runs standard Amazon Linux 2023 (AL2023) nodes.
  These nodes host only Karpenter controller, CoreDNS, and metrics-server -- EKS system
  infrastructure, not customer-bearing workloads. Platform and application workloads run
  exclusively on Karpenter-provisioned nodes, which will be migrated to FIPS-enabled RHEL nodes
  as part of the RHEL AMI work. This scope boundary is an accepted tradeoff for operational
  reliability.

## Consequences

### Positive

- Self-managed Karpenter architecture enables future FIPS compliance: RHEL nodes with FIPS mode can be
  configured via `EC2NodeClass` userData once the RHEL AMI work is complete, providing
  node-level FIPS-validated cryptographic modules for customer-bearing compute.
- Bootstrap is reliable: the bootstrap node group provisions nodes immediately, ArgoCD installs
  cleanly, and retry-with-backoff guarantees NodePool creation succeeds once Karpenter is ready.
- Self-managed Karpenter can be independently upgraded via Helm chart version changes in the ArgoCD
  Application without waiting for AWS EKS Auto Mode support cycles.
- The `EC2NodeClass` and `NodePool` are managed exclusively by ArgoCD via the eks-nodepool
  Application, providing full GitOps lifecycle (version control, drift detection, self-healing).

### Negative

- Karpenter controller, CoreDNS, and metrics-server run on standard AL2023 m7i.xlarge nodes. These
  are platform system components, not customer-bearing workloads. CoreDNS and metrics-server are
  AWS-managed EKS addons; Karpenter is OSS software installed and managed by ArgoCD.
- Platform and application workloads currently run on standard Bottlerocket nodes. FIPS-validated
  compute (RHEL with FIPS mode enabled) will be delivered as part of the RHEL AMI work.
- Two IAM roles are required: the IRSA-backed Karpenter controller role, and
  `karpenter-node-role`, shared by both the `karpenter-bootstrap` node group and
  Karpenter-provisioned nodes.

## Cross-Cutting Concerns

### Reliability

- **Scalability**: The workloads `NodePool` handles all platform and application workloads.
  Karpenter scales reactively on pending pods using EC2 instance provisioning.
- **Observability**: Karpenter NodeClaims are visible via `kubectl get nodeclaims`. CloudWatch
  logs for the ECS bootstrap task provide a full audit trail.
- **Resiliency**: The `karpenter-bootstrap` node group is a fixed-size managed node group (2
  nodes); AWS manages availability. Karpenter nodes are ephemeral and replaced automatically.

### Security

- The `EC2NodeClass` selects subnets and security groups via cluster-owned tags, ensuring nodes
  land in the correct private subnets with correct network policies.
- Karpenter controller IAM role uses IRSA (ServiceAccount annotation on `kube-system/karpenter`)
  with least-privilege SQS, EC2, and IAM instance profile permissions.
- Karpenter node IAM role (`${cluster_id}-karpenter-node-role`) is referenced directly in the
  `EC2NodeClass`, scoping node permissions to a cluster-specific role.
- FIPS-validated cryptographic modules (RHEL with FIPS mode enabled) will be configured via
  `EC2NodeClass` userData once the RHEL AMI work is complete, satisfying the node-level portion
  of FIPS 140-2/140-3 requirements for SC-13. Full SC-13 coverage requires validated cryptography
  across the control plane and data paths as well.

### Performance

- `consolidateAfter: 60s` on the workloads `NodePool` enables rapid scale-down of idle capacity.
- Future FIPS-mode RHEL nodes will have minimal performance overhead for general-purpose workloads.

### Cost

- The `karpenter-bootstrap` node group (2x m7i.xlarge) runs continuously. Karpenter workload nodes
  are on-demand EC2 instances provisioned reactively.
- `WhenEmpty` consolidation reclaims idle Karpenter capacity promptly, reducing EC2 spend.

### Operability

- The `EC2NodeClass` and `NodePool` are managed by ArgoCD via the eks-nodepool Application.
  Day-2 changes are made via GitOps — edit the chart in `argocd/config/<cluster-type>/eks-nodepool/`
  and ArgoCD syncs the change automatically.
- Adding a new cluster type requires creating an `argocd/config/<cluster-type>/eks-nodepool/`
  directory with appropriate `EC2NodeClass` and `NodePool` manifests. The ApplicationSet
  automatically generates an Application for any directory under `argocd/config/<cluster-type>/`.
- EC2 interruption events (spot reclamation, instance retirement) are handled by Karpenter via
  an SQS queue wired to EventBridge rules provisioned by the `eks-cluster` module.
- FIPS configuration will be added to the `EC2NodeClass` userData field once RHEL AMI support
  is implemented.
