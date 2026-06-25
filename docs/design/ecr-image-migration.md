# ECR Image Migration: Moving Platform and HCP Images Away From Quay

**Last Updated Date**: 2026-06-25

## Summary

Migrate all images consumed by the ROSA Regional Platform — both the Hosted Control Plane (HCP)
dataplane images and the platform operational images (kubeapplier, hyperfleet-operator, etc.) —
from Quay.io to Amazon ECR. OCP images already mirrored to ECR by the OpenShift release process
are reused directly. Platform images built via Konflux are mirrored into the same regional ECR
repositories using the existing OCP mirroring infrastructure, extended to cover platform image
sets. A unified IAM authentication path covers both image sets.

## Context

- **Problem Statement**: Zero-egress Hosted Control Plane environments cannot
  reach Quay.io at all. OCP already publishes a mirrored copy of its release images to regional
  ECR repositories to satisfy this requirement. The platform should reuse those mirrored images
  rather than maintaining a separate mirroring pipeline or continuing to depend on public Quay
  endpoints.

  As part of reducing and minimizing dependencies on infrastructure outside of AWS, the intention
  is to move all images required to run the platform to ECR as opposed to Quay.

- **Constraints**:
  - The HCP dataplane images must be sourced from ECR to support zero-egress control plane
    environments — however, the `--zero-egress` flag in HyperShift carries side effects beyond
    image sourcing (e.g., restricting network path modifications) that are undesirable for standard
    Hosted Clusters. ECR image sourcing must therefore be achieved without setting this flag.
  - Platform images (kubeapplier, hyperfleet-operator, and others) must be available in the same
    regional ECR repositories as OCP images so that MC/RC workloads can pull them without public
    internet egress.
  - The authentication mechanism for ECR must cover both image sets (OCP HCP dataplane images and
    platform operational images) using a single, unified approach.
  - Konflux is the build system for platform images; the mirroring pipeline will use the existing
    mirroring infrastructure.

- **Assumptions**:
  - OCP continues to mirror its release images to regional ECR repositories as part of the standard
    release process. The exact repository paths and tagging conventions for those mirrors are
    treated as stable inputs.
  - The existing OCP ECR mirroring infrastructure (tooling, IAM roles, regional replication
    configuration) can be extended to include platform image sets without a full rewrite.
  - ECR private repositories in the relevant AWS accounts and regions are, or can be, accessible
    to the IAM identities associated with MC and RC node pools and control plane pods.
  - Authentication to ECR for image pulls — particularly for HCP dataplane pods running inside
    Hosted Clusters — is achievable, but the exact mechanism requires investigation (see
    [Authentication](#authentication) below).

## Alternatives Considered

1. **Mirror images to a self-managed registry (e.g., a registry running on the RC)**: Gives full
   control over availability but introduces significant operational burden: registry lifecycle
   management, storage provisioning, replication, and a new failure domain. Rejected.

2. **Use ECR for dataplane images only, retain Quay for infra images**: Introduces two
   paths for obtaining images. Rejected.

## Design

### Image Set Breakdown

There are two distinct sets of images that need to move to ECR:

#### Set 1: HCP Dataplane Images

These are the OCP component images that run inside the Hosted Control Plane (API server,
etcd, ingress operator, etc.). They are built by the OCP release process on Quay and are already
mirrored by OCP to regional ECR repositories as part of the standard release pipeline.

The goal is to configure HyperShift to always pull these images from ECR rather than from Quay,
regardless of whether the Hosted Cluster is in a zero-egress environment.

#### Set 2: Platform Operational Images

These are images required to operate the Regional Platform itself — running on MCs and RCs.
Examples include:

- `kubeapplier`
- `hyperfleet-operator`
- Other platform controllers and tooling

These images are built via Konflux and are currently sourced from Quay at runtime. They need to
be mirrored to ECR and pulled from there instead.

### HyperShift Configuration: ECR Without `--zero-egress`

HyperShift's `--zero-egress` flag was designed for environments with no public internet access.
Setting it causes HyperShift to source control plane images from ECR mirrors, but it also applies
network path restrictions and other behavioural changes that are undesirable for standard Hosted
Clusters (e.g., it may restrict outbound network paths that are expected to be available in a
normal hosted cluster).

Since the goal is to use ECR for image sourcing universally — not just in zero-egress environments
— an alternative mechanism is needed to force HyperShift to always pull from ECR. The specific
approach is still being determined, but candidate mechanisms include:

- Configuring HyperShift's image override mechanism (e.g., via `ImageContentSources` or
  `ImageDigestMirrorSet` on the management cluster) to redirect Quay image references to their
  ECR equivalents.
- Providing a custom release image or image lookup override in the `HostedCluster` spec that
  points directly to ECR-hosted digests.
- Patching HyperShift's image resolution logic to treat ECR as the primary source unconditionally.

The chosen approach must ensure that HyperShift resolves all control plane images to ECR without
activating the broader `--zero-egress` mode. This will require investigation and likely
coordination with the HyperShift upstream team.

### Mirroring: Extending the OCP Pipeline for Platform Images

OCP already operates a mirroring pipeline that replicates release images from Quay to regional ECR
repositories. Rather than building a separate mirroring mechanism for platform images, the existing
pipeline will be extended to include platform image sets.

The extension will:

1. Accept platform image lists (produced by Konflux build outputs) as an additional input to the
   mirroring configuration.
2. Mirror platform images to the same regional ECR structure used for OCP images, so that the same
   repository conventions and IAM access patterns apply.
3. Replicate to all regions where OCP images are currently mirrored, maintaining geographic
   consistency.

The specifics of how Konflux build outputs are fed into the mirroring pipeline (e.g., via image
manifests, SBOMs, or a dedicated image list artifact) need to be defined as part of implementation.

### Authentication

Authentication to ECR for image pulls is required in two contexts:

1. **MC/RC node pools and system components**: EKS nodes pulling platform operational images from
   ECR. This is relatively straightforward — EKS node IAM roles can be granted:
   - `ecr:GetAuthorizationToken` with `Resource: "*"` (this action is account-level and cannot be
     scoped to specific repositories; attempting to restrict it to a repository ARN results in an
     `AccessDeniedException`).
   - `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` with `Resource` limited to the specific
     repository ARNs for platform and OCP images (least-privilege, repository-scoped).

   The kubelet handles token refresh automatically via the ECR credential provider plugin (enabled
   by default on EKS).

2. **HCP dataplane pods inside Hosted Clusters**: Pods running inside Hosted Clusters need to pull
   images from ECR. Static `imagePullSecrets` are not suitable here because ECR authorization
   tokens expire after 12 hours, causing image pull failures on any new pod start after token
   expiry.

   The preferred approach is a dynamic credential mechanism such as AWS Pod Identity (EKS Pod
   Identity Associations) or IRSA (IAM Roles for Service Accounts), which allows the HyperShift
   Operator to obtain short-lived ECR tokens on demand without operator intervention. An
   investigation should determine which mechanism integrates most cleanly with HyperShift's
   existing image pull handling (e.g., whether HyperShift can refresh and inject a rotating ECR
   token into the control plane namespace, or whether a sidecar credential rotation controller is
   required). The goal is that a single IAM identity or dynamic pull mechanism covers both OCP HCP
   dataplane images and platform operational images from ECR, with no manual token rotation.

```mermaid
flowchart LR
  subgraph MC_RC["MC / RC Nodes"]
    kubelet["kubelet\n(node IAM role)"]
  end

  subgraph HCP["HCP Control Plane Pods"]
    hcp_pods["etcd / apiserver\ningress / etc"]
  end

  subgraph ECR["ECR (regional)"]
    ocp_imgs["OCP images\nPlatform images"]
  end

  kubelet -->|"ECR credential provider\n(auto token refresh)"| ocp_imgs
  hcp_pods -->|"HyperShift dynamic auth\n(Pod Identity / IRSA)"| ocp_imgs
```

## Consequences

### Positive

- Eliminates runtime dependency on Quay.io for both HCP dataplane images and platform operational
  images, reducing infra dependencies.
- Platform images gain the same regional redundancy and proximity as OCP images, reducing pull
  latency and transfer costs.
- A single, unified auth mechanism for ECR simplifies credential management and reduces the number
  of distinct IAM patterns to maintain.
- Reusing the existing OCP mirroring pipeline for platform images avoids duplicating mirroring
  infrastructure and keeps the operational model consistent.

### Negative

- The ECR mirroring pipeline becomes a critical path dependency: if mirroring fails, new image
  versions will not be available in ECR. The existing OCP pipeline presumably has reliability
  requirements; extending it to cover platform images increases its blast radius.
- ECR repository provisioning (IAM policies, lifecycle rules, replication configuration) must be
  managed per region and per image set, adding Terraform/IaC surface area.
- Forcing HyperShift to pull from ECR without `--zero-egress` requires either upstream changes or
  a local override mechanism that may need to be maintained across HyperShift upgrades.

## Cross-Cutting Concerns

### Reliability

- **Scalability**: ECR scales automatically. Regional replication ensures images are available
  close to the clusters that need them. No capacity planning is required for the registry itself.
- **Observability**: ECR pull failures surface as pod image pull errors (`ImagePullBackOff`).
  Alerting should be added for sustained pull failure rates on both MCs/RCs and HCP control plane
  namespaces. Mirroring pipeline failures should produce actionable alerts before they affect
  running clusters (images already pulled are cached on nodes).
- **Resiliency**: Nodes cache pulled images locally. A transient ECR outage will not affect already
  running pods, only new pod starts or node replacements. Mirroring pipeline failures need to be
  caught before node rotation forces re-pulls of images that are no longer available in ECR.

### Security

- ECR repositories should be private with resource-based policies restricting access to known AWS
  account IDs and IAM roles. Cross-account pulls (e.g., Hosted Cluster node roles in customer
  accounts) may require explicit repository policy statements.
- Leverage existing vulnerability visibility through existing platform mechanisms.
- The auth mechanism for HCP dataplane pods must not grant overly broad ECR permissions. Least
  privilege applies: pull access to specific repositories only, not `ecr:*` on all repositories.
- Short-lived ECR tokens (12-hour expiry) reduce credential exposure compared to long-lived Quay
  robot account tokens.

### Cost

- ECR charges for storage and data transfer. Platform images are small relative to OCP release
  images; the incremental storage cost of adding platform images to the mirroring pipeline is
  expected to be low.
- Pulling images from ECR within the same region incurs no data transfer charges. Cross-region
  pulls are charged; regional replication ensures pulls are always intra-region.
- Lifecycle policies should be configured on ECR repositories to expire old image tags and control
  storage growth.

### Operability

- The mirroring pipeline extension must be automated. Manual mirroring of platform images is not
  acceptable at the cadence of Konflux builds.
- ECR credential rotation for MCs/RCs is handled automatically by the EKS ECR credential provider.
  The HCP dataplane auth mechanism must similarly not require manual intervention for token refresh.
- Repository provisioning (new platform image repositories) should be Terraform-managed and follow
  the same conventions as existing OCP ECR repositories.
- Runbooks are needed for: mirroring pipeline failure, ECR auth failures on HCP pods, and adding
  new platform images to the mirroring configuration.

## Open Questions / Areas Requiring Investigation

1. **HCP dataplane auth**: What is the correct mechanism to provide ECR credentials to pods inside
   a Hosted Cluster's control plane namespace on the management cluster? Can HyperShift's pull
   secret handling be extended, or is a credential injection controller required?

2. **HyperShift ECR override without `--zero-egress`**: What is the minimal change required to
   make HyperShift resolve all control plane images from ECR by default? Is this achievable via
   `ImageDigestMirrorSet` on the management cluster, or does it require changes to HyperShift's
   image resolution code?

3. **OCP mirroring pipeline extension**: What is the interface for adding platform image sets to
   the existing OCP mirroring pipeline? Who owns that pipeline, and what is the process for
   contributing extensions?

4. **Repository naming conventions**: Platform images will be mirrored into the same regional ECR
   repository structure as OCP images (this is a constraint established in the design). The open
   question is how to namespace them within that structure — for example, should platform images
   share the same repository namespace as OCP release images, or live under a distinct
   platform-specific prefix within the same ECR registry? The answer affects IAM policy scoping
   (whether a single repository ARN pattern covers both sets) and lifecycle rule management.

5. **Cross-account ECR access for Hosted Cluster nodes**: If Hosted Cluster nodes run in customer
   AWS accounts and need to pull from platform-account ECR repositories, what cross-account IAM
   setup is required? Is this handled by HyperShift, or does the platform need to manage it?
