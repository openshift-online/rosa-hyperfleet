# AutoNode (Karpenter) Support for HCP Clusters

**Last Updated Date**: 2026-06-17

## Summary

The ROSA Regional Platform adds AutoNode (Karpenter) support to Hosted Control Plane (HCP) clusters
by propagating an optional `karpenterControllerRoleARN` field from the cluster spec through the
HyperFleet adapter into the `HostedCluster` CR on the management cluster. This enables HyperShift
to deploy and configure a Karpenter controller in the hosted control plane namespace, allowing
customers to use Karpenter-based autoscaling on their guest clusters.

## Context

- **Problem Statement**: The ROSA Regional Platform creates ROSA HCP clusters via the HyperFleet
  adapter, which renders a `HostedCluster` CR and applies it to the management cluster via
  ManifestWork. AutoNode is a GA feature in OCP 4.22 / ROSA HCP that requires
  `spec.platform.aws.karpenterControllerRoleARN` to be set on the `HostedCluster`. Without this
  field the Karpenter controller is not deployed and AutoNode is unavailable to customers.
- **Constraints**:
  - The `karpenterControllerRoleARN` is created in the **customer** AWS account and cannot be
    provisioned by the platform — customers must create it using the IAM setup documented in
    [hostedcluster-autonode.md](../hostedcluster-autonode.md).
  - AutoNode requires HyperShift Operator v0.1.75+ and OCP 4.22+.
  - The field is optional. Clusters without it continue to work normally using HyperShift
    NodePools.
- **Assumptions**: AutoNode is GA; the `TechPreviewNoUpgrade` feature gate has been removed from
  HyperShift (see [PR #8166](https://github.com/openshift/hypershift/pull/8166)).

## Alternatives Considered

1. **Require AutoNode for all clusters**: Mandatory Karpenter support for every HCP cluster.
   Increases IAM setup complexity for all customers. Most customers do not require Karpenter.
   Rejected.

2. **Provision the Karpenter IAM role automatically**: Platform creates the role in the customer
   account during cluster-iam setup. Requires broader IAM permissions in the customer account and
   creates an opaque dependency. Rejected in favour of self-service customer setup.

3. **Optional field propagated through the adapter (chosen)**: The `karpenterControllerRoleArn`
   field is stored in the cluster spec and propagated to the `HostedCluster` CR only when
   provided. Zero impact on clusters that do not use AutoNode. **Chosen.**

## Design Rationale

- **Justification**: Propagating the optional field through the existing adapter pipeline is the
  minimal change required. It follows the same pattern used for other optional ARN fields (`storageARN`,
  `networkARN`, etc.) in the adapter task config.
- **Evidence**: HyperShift sets `spec.platform.aws.karpenterControllerRoleARN` on the
  `HostedCluster` CR when provided, which causes the control plane operator to deploy the
  Karpenter controller pod in the `clusters-<cluster-id>` namespace on the management cluster.
- **Comparison**: Alternative 1 (mandatory) creates unnecessary barriers for customers not
  using Karpenter. Alternative 2 (automatic IAM) increases platform complexity and attack surface
  without benefit for the majority of customers.

## Consequences

### Positive

- Customers can enable Karpenter autoscaling on their ROSA HCP clusters by providing a single
  IAM role ARN at cluster creation time.
- No change to clusters that do not supply `karpenterControllerRoleArn` — the field is
  conditional in the ManifestWork template.
- The IAM role setup follows the same IRSA pattern already used for all other HCP operator roles,
  keeping the security model consistent.

### Negative

- Customers must create and manage the Karpenter controller IAM role in their own AWS account.
  This adds a one-time setup step before cluster creation.
- The Karpenter controller IAM role trust policy is tied to the cluster OIDC provider URL, which
  is determined after OIDC setup. Customers must complete `rosactl cluster-oidc create` before
  they can create the role (or use a deferred trust policy update).

## Cross-Cutting Concerns

### Reliability

- **Scalability**: Karpenter runs as a single controller pod in the hosted control plane namespace.
  At scale, CPU usage may be elevated — see [CSC guidance](../hostedcluster-autonode.md) and
  CNTRLPLANE-3135.
- **Observability**: Karpenter exposes Prometheus metrics. The `observe-fleetsharding: "true"`
  annotation on the `HostedCluster` is required to enable guest cluster metrics flow
  (ROSAENG-1097).
- **Resiliency**: Karpenter failures do not affect the hosted control plane or existing
  HyperShift NodePools. Karpenter-managed nodes are independent of the standard NodePool
  lifecycle.

### Security

- The `karpenterControllerRoleARN` is scoped to the cluster OIDC provider and Karpenter service
  account via IRSA — no other workload can assume the role.
- Karpenter-created EC2 instances are tagged with `red-hat-managed: "true"` (enforced by managed
  policy conditions), preventing scope escalation via the `PassRole` permission.
- Instance size validation via ValidatingAdmissionPolicies ensures nodes have at least 4 vCPUs,
  maintaining a minimum security and reliability baseline.

### Cost

- Karpenter provisions nodes on demand and consolidates (terminates) underutilised nodes,
  potentially reducing EC2 costs compared to fixed NodePool replicas.
- The Karpenter controller pod runs in the hosted control plane namespace — a small additional
  resource cost on the management cluster.

### Operability

- The `karpenterControllerRoleARN` field is set at cluster creation and is immutable via the
  current adapter. Day-2 changes would require cluster recreation.
- AutoNode cannot be disabled via the API after enablement. Customers can stop Karpenter from
  provisioning new nodes by deleting all `NodePool` resources on the guest cluster.
