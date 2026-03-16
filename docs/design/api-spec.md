# ROSA Regional Platform API Specification

| | |
|---|---|
| **Authors** | ROSA Regionality API working group |
| **Status** | Draft |
| **Date** | 2026-03-16 |
| **Implements** | [HCM-ADR-0300](../../docs/design-decisions/) |
| **Repository** | `rosa-regional-platform-api` |

## Table of Contents

- [Summary](#summary)
- [Design Principles](#design-principles)
- [Resource Hierarchy](#resource-hierarchy)
- [Core Resources](#core-resources) - ManagedCluster, NodePool, AutoNodePool
- [Sub-Resources](#sub-resources) - Identity Providers, Break Glass Credentials, Ingresses, Upgrade Policies, Log Forwarders, Tuning Configs, Kubelet Configs, Registry Configuration, Manifests
- [Read-Only Resources](#read-only-resources) - Versions, Machine Types, Version Gates
- [Feature Parity Mapping](#feature-parity-mapping)
- [CLM Integration](#clm-integration)
- [Design Decisions](#design-decisions)

## Summary

This document defines the API specification for the ROSA Regional Platform (RRP) service. The API wraps the Hyperfleet CLM API and is implemented in `rosa-regional-platform-api`. It follows a Kubernetes-like declarative model while minimizing abstraction over HyperShift.

## Design Principles

1. **Kubernetes feel without Kubernetes**: Declarative resources with `kind`, `metadata`, `spec`, `status` sections
2. **Passthrough over abstraction**: Pass HyperShift CRD fields directly where possible, reducing our API surface
3. **Envelope pattern**: Only wrap HyperShift CRDs with "envelope fields" for things the platform manages outside of HyperShift
4. **Defaulting**: Like a Kubernetes API server, the platform applies defaulting to submitted specs. Unspecified fields are filled with platform-managed default values (GitOps-configured). For infrastructure resources (VPC, OIDC, IAM roles), the platform provisions them during defaulting if not provided by the customer. On GET, the API returns the fully-defaulted spec. This dramatically simplifies onboarding while preserving flexibility for advanced users who can override any defaulted field.
5. **NodePools as sub-resources**: `/clusters/{id}/nodepools/{id}` - separate lifecycle from clusters
6. **No automatic NodePool creation**: Creating a cluster does NOT create NodePools
7. **AWS-first**: Focus on AWS (ROSA HCP), other providers can be added later

## Resource Hierarchy

```
api/v1/
  clusters/                           # ManagedCluster CRUD
  clusters/{id}/
    status                            # Cluster status (read-only)
    nodepools/                        # NodePool CRUD
    nodepools/{id}/
      status                          # NodePool status (read-only)
      upgrade_policies/               # NodePool upgrade scheduling
    auto_nodepools/                   # Karpenter AutoNodePool CRUD
    identity_providers/               # IDP CRUD
    identity_providers/{id}/
      htpasswd_users/                 # HTPasswd user management
    ingresses/                        # Ingress CRUD
    upgrade_policies/                 # Control plane upgrade scheduling
    tuning_configs/                   # TuningConfig CRUD
    kubelet_configs/                  # KubeletConfig CRUD
    registry_config                   # Registry config (singleton)
    external_configuration/labels/    # External labels
    log_forwarders/                   # Log forwarding config
    break_glass_credentials/          # Emergency access
    private_link_principals/          # Day-2 PrivateLink principal management
    backup_config                     # Backup configuration
    manifests/                        # Custom K8s resources
    gate_agreements/                  # Version gate acknowledgements
    external_auth/                    # External authentication providers
  versions/                           # Available OCP versions
  machine_types/                      # Available instance types
  version_gates/                      # Upgrade gate definitions
```

---

## Core Resources

### ManagedCluster

The primary resource. Contains an envelope around a HyperShift `HostedCluster` spec.

```yaml
kind: ManagedCluster
apiVersion: v1
metadata:
  id: <uuid>                     # Platform-assigned
  name: my-cluster               # 3-53 chars, lowercase alphanum + hyphens
  labels: {}                     # Key-value metadata
  creation_timestamp: <rfc3339>
  deletion_timestamp: <rfc3339>  # Set when delete requested
spec:
  # === ENVELOPE FIELDS (platform-managed, NOT passed to HyperShift) ===

  # Delete protection
  delete_protection:
    enabled: false

  # Cluster expiration
  expiration_timestamp: <rfc3339>   # Auto-delete after this time

  # Properties (arbitrary key-value metadata)
  properties: {}

  # IAM Permission Boundary (not in HyperShift, applied during role setup)
  permission_boundary: <arn>

  # Role Policy Bindings (arbitrary IAM policies, not in HyperShift)
  role_policy_bindings:
    - name: my-binding
      role_arn: <arn>
      type: operator                  # account | operator
      policies:
        - arn: <policy-arn>
          type: managed               # managed | inline | customer

  # Log forwarding (day-1 inline, also available as day-2 sub-resource)
  log_forwarders:
    - type: cloudwatch
      cloudwatch:
        region: us-east-1
        group_name: /rosa/cluster-id
        role_arn: <arn>
        log_types: [audit, infrastructure]

  # Backup configuration (day-1 inline, also available as day-2 singleton)
  backup_config:
    enabled: true
    schedule: "0 */6 * * *"           # Cron expression

  # === HOSTEDCLUSTER PASSTHROUGH ===
  # The platform applies defaulting to the hosted_cluster spec.
  # The customer submits only the fields they want to set.
  # On GET, the API returns the fully-defaulted spec.
  hosted_cluster:
    ...

status:
  conditions: []                      # Standard k8s-like conditions
  version:
    desired: <version>
    current: <version>
    available_updates: []
  control_plane_endpoint:
    host: <api-url>
    port: 6443
  kubeconfig: <secret-ref>
  phase: Provisioning | Ready | Deleting | Error
```

#### HostedCluster Defaulting Reference

The platform applies defaulting to the `hosted_cluster` spec. Unspecified fields are filled with platform-managed default values (GitOps-configured, may vary by region). For provisioned resources (VPC, OIDC, IAM roles), the platform creates them during defaulting and populates the spec with the resulting values.

| Field | Default Value | Notes |
|---|---|---|
| `platform.type` | `AWS` | |
| `platform.aws.endpoint_access` | `Private` | |
| `platform.aws.resource_tags` | `[]` | |
| `platform.aws.additional_allowed_principals` | `[]` | |
| `platform.aws.cloud_provider_config` | *platform-provisioned* | Platform creates VPC if nil |
| `platform.aws.roles_ref` | *platform-provisioned* | Platform creates roles with managed policies if nil |
| `issuer_url` | *platform-provisioned* | Platform creates OIDC provider if nil |
| `networking.machine_network` | `[{cidr: "10.0.0.0/16"}]` | |
| `networking.cluster_network` | `[{cidr: "10.132.0.0/14"}]` | |
| `networking.service_network` | `[{cidr: "172.31.0.0/16"}]` | |
| `networking.network_type` | `OVNKubernetes` | |
| `etcd.management_type` | `Managed` | |
| `etcd.managed.storage.type` | `PersistentVolume` | |
| `etcd.managed.storage.persistent_volume.size` | `8Gi` | |
| `secret_encryption` | *platform-managed KMS* | |
| `services` | *platform-managed* | |
| `fips` | `false` | Immutable after creation |
| `controller_availability_policy` | `HighlyAvailable` | |
| `infrastructure_availability_policy` | `SingleReplica` | |
| `olm_catalog_placement` | `management` | |
| `dns.base_domain` | *platform-assigned* | Platform always assigns |

#### Example: Minimal Cluster Creation

The customer provides only required fields. Everything else is defaulted.

```yaml
spec:
  hosted_cluster:
    release:
      image: quay.io/openshift-release-dev/ocp-release:4.17.0-multi
    platform:
      aws:
        region: us-east-1
```

#### Example: Overriding Defaults

The customer specifies only the fields they want to override. Unspecified fields still get their default values.

```yaml
spec:
  hosted_cluster:
    release:
      image: quay.io/openshift-release-dev/ocp-release:4.17.0-multi
    platform:
      aws:
        region: us-east-1
        cloud_provider_config:         # BYO VPC (overrides provisioning)
          vpc: vpc-0123456789abcdef0
          subnet: subnet-abcdef
        roles_ref:                     # BYO IAM roles (overrides provisioning)
          ingress_arn: arn:aws:iam::123456789012:role/my-ingress
          image_registry_arn: arn:aws:iam::123456789012:role/my-registry
          storage_arn: arn:aws:iam::123456789012:role/my-storage
          network_arn: arn:aws:iam::123456789012:role/my-network
          kube_cloud_controller_arn: arn:aws:iam::123456789012:role/my-kcc
          node_pool_management_arn: arn:aws:iam::123456789012:role/my-npm
          control_plane_operator_arn: arn:aws:iam::123456789012:role/my-cpo
        endpoint_access: PublicAndPrivate  # Override default (Private)
        resource_tags:
          - key: environment
            value: production
    issuer_url: https://my-oidc.s3.amazonaws.com  # BYO OIDC
    networking:
      cluster_network: [{cidr: "10.128.0.0/14"}]  # Override just this
    fips: true                                      # Override default (false)
    secret_encryption:
      type: kms
      kms:
        aws:
          active_key:
            arn: arn:aws:kms:us-east-1:123456789012:key/my-key
    configuration:
      proxy:
        http_proxy: http://proxy.example.com:3128
        https_proxy: http://proxy.example.com:3128
        no_proxy: .cluster.local,.svc,10.0.0.0/8
```

#### Passthrough Analysis for HostedCluster

All passthrough fields support **defaulting**. The platform fills in unspecified fields with default values. The customer can override any defaulted field.

| HyperShift Field | Passthrough? | Default | Notes |
|---|---|---|---|
| `release` | YES | None (required) | Customer must specify OCP version |
| `platform.aws.region` | YES | None (required) | Customer must specify region |
| `platform.aws.cloud_provider_config` | YES | Platform-provisioned VPC | BYO or platform creates VPC (3-AZ, private subnets, NAT GWs) |
| `platform.aws.roles_ref` | YES | Platform-created roles (managed policies) | BYO or platform creates 7 operator IRSA roles |
| `platform.aws.endpoint_access` | YES | `Private` | Customer can override to `PublicAndPrivate` |
| `platform.aws.resource_tags` | YES | `[]` | Customer adds custom tags |
| `platform.aws.additional_allowed_principals` | YES | `[]` | PrivateLink principals |
| `platform.aws.shared_vpc` | YES | None | Only if customer uses shared VPC |
| `issuer_url` | YES | Platform-created OIDC | BYO or platform creates OIDC provider |
| `networking` | YES | `10.0.0.0/16` machine, `10.132.0.0/14` cluster, `172.31.0.0/16` service, OVNKubernetes | Customer overrides any CIDR or network type |
| `etcd` | YES | Managed, PersistentVolume, 8Gi | Unlikely to be overridden |
| `secret_encryption` | YES | Platform-managed KMS | Customer can BYO KMS key |
| `services` | YES | Platform-managed | Customer can override listening mode |
| `fips` | YES | `false` | Immutable at creation |
| `autoscaling` | YES | None (disabled) | Customer enables if needed |
| `configuration` | YES | None | Customer provides proxy, OAuth, API server config, etc. |
| `image_content_sources` | YES | `[]` | Customer adds image mirrors |
| `additional_trust_bundle` | YES | Custom CA certs |
| `dns` | PARTIAL | Platform manages base domain assignment |
| `controller_availability_policy` | YES | HA or single replica |
| `infrastructure_availability_policy` | YES | HA or single replica |
| `olm_catalog_placement` | YES | management or guest |
| `capabilities` | YES | Enable/disable optional capabilities |
| `auto_node` | YES | Karpenter config |
| `pull_secret` | NO | Platform manages pull secrets internally |
| `ssh_key` | YES | Customer-provided SSH keys |
| `issuer_url` | YES (optional) | BYO OIDC; if omitted, platform creates and manages OIDC provider |
| `infra_id` | NO | Platform-generated |
| `cluster_id` | NO | Platform-generated |

### NodePool

Sub-resource of ManagedCluster. Envelope around HyperShift `NodePool` spec. Like ManagedCluster, the platform applies **defaulting** to the `node_pool` spec - the customer submits only the fields they want to set.

```yaml
kind: NodePool
apiVersion: v1
metadata:
  id: <uuid>
  name: my-nodepool             # 3-15 chars
  labels: {}
  creation_timestamp: <rfc3339>
spec:
  # === ENVELOPE FIELDS ===

  # (Currently none identified - all fields pass through to HyperShift)
  # Future: billing tags, compliance labels, etc.

  # === NODEPOOL PASSTHROUGH ===
  # Customer submits only what they want to set.
  # Everything else is defaulted by the platform.
  node_pool:
    ...

status:
  replicas: 3
  version: 4.16.5
  conditions: []
  phase: Scaling | Ready | Upgrading | Error
```

#### NodePool Defaulting Reference

| Field | Default Value | Notes |
|---|---|---|
| `release.image` | *inherits from cluster* | Defaults to cluster's release |
| `platform.type` | `AWS` | |
| `platform.aws.instance_type` | `m5.xlarge` | |
| `platform.aws.subnet` | *from cluster VPC* | Defaulted from cluster's VPC config |
| `platform.aws.image_type` | `Linux` | |
| `platform.aws.root_volume.size` | `300` | GiB |
| `platform.aws.root_volume.type` | `gp3` | |
| `platform.aws.root_volume.encrypted` | `true` | |
| `platform.aws.resource_tags` | `[]` | |
| `platform.aws.placement.tenancy` | `default` | |
| `replicas` | `2` | XOR with auto_scaling |
| `management.upgrade_type` | `Replace` | Immutable after creation |
| `management.replace.strategy` | `RollingUpdate` | |
| `management.replace.rolling_update.max_surge` | `1` | |
| `management.replace.rolling_update.max_unavailable` | `0` | |
| `management.auto_repair` | `true` | |
| `node_drain_timeout` | `15m` | |
| `node_volume_detach_timeout` | `5m` | |
| `arch` | `amd64` | Immutable after creation |

#### Example: Minimal NodePool Creation

```yaml
spec:
  node_pool:
    platform:
      aws:
        instance_type: m5.2xlarge
```

#### Example: Overriding NodePool Defaults

```yaml
spec:
  node_pool:
    platform:
      aws:
        instance_type: g5.xlarge        # GPU instance
        subnet:
          id: subnet-abcdef             # Specific subnet
        root_volume:
          size: 500
          type: io2
          iops: 10000
        resource_tags:
          - key: team
            value: ml-platform
    auto_scaling:                        # Overrides default replicas
      min: 0
      max: 10
    arch: arm64                          # Override default (amd64)
    node_labels:
      workload: gpu
    taints:
      - key: nvidia.com/gpu
        value: "true"
        effect: NoSchedule
```

#### Passthrough Analysis for NodePool

All passthrough fields support **defaulting**.

| HyperShift Field | Passthrough? | Default | Notes |
|---|---|---|---|
| `release` | YES | Inherits from cluster | Version selection |
| `platform.aws.instance_type` | YES | `m5.xlarge` | EC2 instance type |
| `platform.aws.subnet` | YES | From cluster VPC | Subnet for nodes |
| `platform.aws.instance_profile` | YES | Platform-provisioned | IAM instance profile |
| `platform.aws.ami` | YES | From release payload | Custom AMI override |
| `platform.aws.image_type` | YES | `Linux` | Linux or Windows |
| `platform.aws.security_groups` | YES | `[]` | Additional security groups |
| `platform.aws.root_volume` | YES | 300 GiB, gp3, encrypted | EBS root volume config |
| `platform.aws.resource_tags` | YES | `[]` | Per-node tags |
| `platform.aws.placement` | YES | `default` tenancy | Tenancy and capacity reservation |
| `replicas` | YES | `2` | XOR with auto_scaling |
| `auto_scaling` | YES | None (disabled) | Min/max autoscaling |
| `management` | YES | Replace, RollingUpdate, auto_repair=true | Upgrade strategy |
| `node_labels` | YES | `{}` | Kubernetes labels on nodes |
| `taints` | YES | `[]` | Node taints |
| `node_drain_timeout` | YES | `15m` | Drain timeout |
| `node_volume_detach_timeout` | YES | `5m` | Volume detach timeout |
| `arch` | YES | `amd64` | CPU architecture (immutable) |
| `tuning_config` | YES | `[]` | References to TuningConfig resources |
| `config` | YES | `[]` | MachineConfig references |
| `cluster_name` | NO | Set by platform | From URL path |
| `paused_until` | YES | None | Pause reconciliation |

#### AutoNode / Karpenter NodePools

For Karpenter-based automatic node provisioning, the `auto_node` field on the ManagedCluster spec enables Karpenter. Karpenter NodePools are a separate concept from traditional NodePools.

Karpenter NodePools are a **separate endpoint** (`/clusters/{id}/auto_nodepools/`). They have a fundamentally different spec (NodeClass, requirements, limits, disruption policies) that doesn't map to the traditional NodePool spec.

Like all resources, the platform applies **defaulting** to unspecified fields.

```yaml
kind: AutoNodePool
apiVersion: v1
metadata:
  id: <uuid>
  name: default
spec:
  auto_node_pool:
    ...
  node_class:
    ...
```

#### AutoNodePool Defaulting Reference

| Field | Default Value | Notes |
|---|---|---|
| `auto_node_pool.disruption.consolidation_policy` | `WhenEmptyOrUnderutilized` | |
| `auto_node_pool.disruption.consolidate_after` | `30s` | |
| `auto_node_pool.weight` | `10` | |
| `node_class.subnet_selector_terms` | *from cluster VPC* | Defaulted from cluster config |
| `node_class.security_group_selector_terms` | *from cluster SGs* | Defaulted from cluster config |
| `node_class.instance_profile` | *platform-provisioned* | Platform creates if nil |
| `node_class.block_device_mappings` | `[300Gi, gp3, encrypted]` | Matches NodePool defaults |

#### Example: Minimal AutoNodePool

```yaml
spec:
  auto_node_pool:
    requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: [on-demand]
      - key: kubernetes.io/arch
        operator: In
        values: [amd64]
```

#### Example: GPU AutoNodePool

```yaml
spec:
  auto_node_pool:
    requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: [on-demand]
      - key: node.kubernetes.io/instance-type
        operator: In
        values: [g5.xlarge, g5.2xlarge]
    limits:
      cpu: 100
      memory: 400Gi
  node_class:
    tags:
      team: ml-platform
```

---

## Sub-Resources

### Identity Providers

**Path**: `/clusters/{id}/identity_providers/`

Identity providers are NOT part of the HyperShift HostedCluster spec. They are managed through the OpenShift OAuth configuration. In the current ROSA architecture, they're a separate API. We keep them separate. Defaulting applies: `mapping_method` defaults to `claim`.

```yaml
kind: IdentityProvider
apiVersion: v1
metadata:
  id: <uuid>
  name: my-github-idp
spec:
  type: github | gitlab | google | htpasswd | ldap | openid  # Required
  mapping_method: claim | lookup | add                         # Default: claim
  # Type-specific config (one of):
  github:
    client_id: <id>
    client_secret: <secret>
    organizations: []
    teams: []
    hostname: ""              # For GitHub Enterprise
  gitlab:
    client_id: <id>
    client_secret: <secret>
    url: https://gitlab.com
  google:
    client_id: <id>
    client_secret: <secret>
    hosted_domain: example.com
  htpasswd:
    # Users managed via sub-resource
  ldap:
    url: ldap://...
    bind_dn: ""
    bind_password: ""
    attributes:
      id: []
      email: []
      name: []
      preferred_username: []
    insecure: false
    ca: ""
  openid:
    client_id: <id>
    client_secret: <secret>
    issuer: https://...
    claims:
      email: []
      name: []
      preferred_username: []
    extra_scopes: []
    extra_authorize_parameters: {}
```

**Sub-resources**:
- `/clusters/{id}/identity_providers/{idp_id}/htpasswd_users/` - HTPasswd user management

#### External Authentication (HCP-specific)

For HCP clusters, external authentication can be configured as an alternative to the built-in OAuth server. This maps to HyperShift's `ExternalAuthConfig`.

```yaml
kind: ExternalAuth
apiVersion: v1
metadata:
  id: <uuid>
  name: my-external-auth
spec:
  # Passthrough to HyperShift ExternalAuth
  issuer:
    url: https://...
    audiences: []
    ca: ""
  clients: []
  claim_mappings:
    username: {}
    groups: {}
  claim_validation_rules: []
```

### Break Glass Credentials

**Path**: `/clusters/{id}/break_glass_credentials/`

Emergency access credentials with expiration.

```yaml
kind: BreakGlassCredential
apiVersion: v1
metadata:
  id: <uuid>
  creation_timestamp: <rfc3339>
spec:
  expiration_timestamp: <rfc3339>     # Required
  username: emergency-admin           # Optional
status:
  kubeconfig: <base64>               # Generated kubeconfig
  expiration_timestamp: <rfc3339>
  conditions: []
```

### Ingresses

**Path**: `/clusters/{id}/ingresses/`

Day-2 ingress controller management. The default ingress is created automatically by the platform. Defaulting applies to all fields.

```yaml
kind: Ingress
apiVersion: v1
metadata:
  id: <uuid>
  name: default
spec:
  # Customer submits only what they want to set.
  listening: internal | external                              # Default: external
  load_balancer_type: NLB | Classic                           # Default: NLB
  wildcard_policy: WildcardsAllowed | WildcardsDisallowed     # Default: WildcardsDisallowed
  namespace_ownership_policy: Strict | InterNamespaceAllowed  # Default: Strict
  route_selectors: {}
  excluded_namespaces: []
  route_namespace_selectors: {}        # Toggle-gated: IngressNamespaceSelectors
  component_routes:                    # Custom hostnames (no defaults)
    console:
      hostname: console.example.com
      tls_secret_ref: <name>
    oauth:
      hostname: oauth.example.com
      tls_secret_ref: <name>
    downloads:
      hostname: downloads.example.com
      tls_secret_ref: <name>
```

### Upgrade Policies

**Control Plane**: `/clusters/{id}/upgrade_policies/`
**NodePool**: `/clusters/{id}/nodepools/{np_id}/upgrade_policies/`

Upgrade scheduling for control plane and node pools independently. Defaulting applies.

```yaml
kind: UpgradePolicy
apiVersion: v1
metadata:
  id: <uuid>
spec:
  version: 4.17.0                                            # Required
  schedule_type: manual | automatic                           # Default: manual
  schedule: "0 2 * * *"              # Cron expression (required if automatic)
  next_run: <rfc3339>                # Computed for automatic
  enable_minor_version_upgrades: false                        # Default: false
  channel: stable-4.17                                        # Default: stable-<current_minor>
status:
  state: pending | scheduled | started | completed | failed | cancelled
  description: ""
  conditions: []
```

### Log Forwarders

**Path**: `/clusters/{id}/log_forwarders/`

Control plane log forwarding configuration. This is an envelope-only resource - not part of HostedCluster spec. No defaulting - all fields are explicit since this is an opt-in feature.

```yaml
kind: LogForwarder
apiVersion: v1
metadata:
  id: <uuid>
  name: cloudwatch-forwarder
spec:
  type: cloudwatch | s3              # Required
  cloudwatch:
    region: us-east-1
    group_name: /rosa/cluster-id
    role_arn: <arn>
    log_types:
      - audit
      - infrastructure
      - application
    cross_account:                    # Toggle-gated: AuditLogCrossAccountSupport
      role_arn: <cross-account-arn>
      external_id: <id>
  s3:
    region: us-east-1
    bucket_name: my-logs-bucket
    role_arn: <arn>
    prefix: rosa-logs/
```

### Tuning Configs

**Path**: `/clusters/{id}/tuning_configs/`

Node Tuning Operator configurations that can be referenced by NodePools.

```yaml
kind: TuningConfig
apiVersion: v1
metadata:
  id: <uuid>
  name: my-tuning
spec:
  # Passthrough to Node Tuning Operator Tuned or PerformanceProfile
  spec: <yaml-string>                 # Serialized Tuned or PerformanceProfile CR
```

### Kubelet Configs

**Path**: `/clusters/{id}/kubelet_configs/`

Custom KubeletConfig resources.

```yaml
kind: KubeletConfig
apiVersion: v1
metadata:
  id: <uuid>
  name: custom-kubelet
spec:
  pod_pids_limit: 4096
  # Additional kubelet configuration fields as needed
```

### Registry Configuration

**Path**: `/clusters/{id}/registry_config`

Single resource (not a collection) for cluster-wide registry settings.

```yaml
kind: RegistryConfig
apiVersion: v1
metadata:
  id: <uuid>
spec:
  image_registry:
    enabled: true                     # Enable/disable internal registry
  registry_sources:
    allowed_registries: []
    blocked_registries: []
    insecure_registries: []
  additional_trusted_ca: {}           # Per-registry CA bundles
  platform_allowlist_id: <ref>        # Reference to platform-level allowlist
```

### Manifests

**Path**: `/clusters/{id}/manifests/`

Custom Kubernetes resources applied to clusters.

```yaml
kind: Manifest
apiVersion: v1
metadata:
  id: <uuid>
  name: my-configmap
spec:
  # Raw Kubernetes manifest
  manifest: <yaml-string>            # Serialized K8s resource
```

---

## Read-Only Resources

### Versions

**Path**: `/versions/`

Available OCP versions for cluster creation and upgrades.

```yaml
kind: Version
apiVersion: v1
metadata:
  id: openshift-v4.17.0
spec:
  raw_id: 4.17.0
  channel_group: stable
  rosa_enabled: true
  hosted_control_plane_enabled: true
  end_of_life_timestamp: <rfc3339>
  available_upgrades: ["4.17.1", "4.18.0"]
```

### Machine Types

**Path**: `/machine_types/`

Available AWS instance types.

```yaml
kind: MachineType
apiVersion: v1
metadata:
  id: m5.xlarge
spec:
  name: m5.xlarge
  cpu:
    cores: 4
  memory:
    size_mib: 16384
  category: general_purpose
  size: xlarge
  gpu:
    count: 0
  arch: amd64
```

### Version Gates

**Path**: `/version_gates/`

Upgrade gates that require acknowledgement before upgrading.

```yaml
kind: VersionGate
apiVersion: v1
metadata:
  id: <uuid>
spec:
  version_raw_id_prefix: "4.17"
  label: "API removal acknowledgement"
  description: "Acknowledge removal of deprecated APIs"
  documentation_url: "https://..."
  sts_only: false
```

**Gate Agreements**: `/clusters/{id}/gate_agreements/`

```yaml
kind: GateAgreement
apiVersion: v1
metadata:
  id: <uuid>
spec:
  version_gate:
    id: <gate-id>
```

---

## Feature Parity Mapping

### Cluster Architecture

| Feature | API Location | Type | Status |
|---|---|---|---|
| ROSA HCP | `ManagedCluster` | Core resource | Must have |
| Multi-AZ Clusters | `hosted_cluster.networking.machine_network` + subnet config | Passthrough | Must have |
| Single-AZ Clusters | Same as above with single AZ | Passthrough | Must have |

### Networking

| Feature | API Location | Type | Status |
|---|---|---|---|
| Private Clusters | `hosted_cluster.platform.aws.endpoint_access: Private` | Passthrough | Must have (default) |
| PublicAndPrivate Clusters | `hosted_cluster.platform.aws.endpoint_access: PublicAndPrivate` | Passthrough | Must have |
| AWS PrivateLink | `hosted_cluster.platform.aws.endpoint_access` + `additional_allowed_principals` | Passthrough | Must have |
| Zero Egress | `hosted_cluster` config + operator mirrors | Passthrough + envelope | Must have |
| BYOVPC | `hosted_cluster.platform.aws.cloud_provider_config.vpc/subnet` (optional; platform creates VPC if omitted) | Passthrough | Must have |
| Shared VPC | `hosted_cluster.platform.aws.shared_vpc` | Passthrough | Must have |
| Cluster-wide Proxy | `hosted_cluster.configuration.proxy` | Passthrough | Must have |
| Additional Trust Bundle | `hosted_cluster.additional_trust_bundle` | Passthrough | Must have |
| Network Type Selection | `hosted_cluster.networking.network_type` | Passthrough | Must have (OVNKubernetes default) |
| Custom Network CIDRs | `hosted_cluster.networking.*_network` | Passthrough | Must have |
| CIDR Block Access Control | `hosted_cluster.networking.api_server.allowed_cidr_blocks` | Passthrough | Must have |
| Additional Allowed Principals | `hosted_cluster.platform.aws.additional_allowed_principals` | Passthrough | Must have |
| PrivateLink Principals (Day-2) | `/clusters/{id}/private_link_principals/` | Separate resource | Must have |
| Transparent Forward Proxies | `hosted_cluster.configuration.proxy` extension | Passthrough | Must have |

### Security & Encryption

| Feature | API Location | Type | Status |
|---|---|---|---|
| FIPS Mode | `hosted_cluster.fips` | Passthrough | Must have |
| etcd Encryption | `hosted_cluster.secret_encryption` | Passthrough | Must have |
| AWS KMS Encryption | `hosted_cluster.secret_encryption.kms.aws` | Passthrough | Must have |
| Backup KMS | `hosted_cluster.secret_encryption.kms.aws.backup_key` | Passthrough | Must have |
| STS / IAM Roles | `hosted_cluster.platform.aws.roles_ref` (7 operator IRSA ARNs) | Passthrough | Must have |
| Permission Boundaries | Envelope field (HyperShift doesn't support) | Envelope | Must have |
| IMDSv2 Enforcement | Passthrough (annotation or spec field) | Passthrough | Must have |
| Delete Protection | `spec.delete_protection` | Envelope | Must have |
| Additional Security Groups | `node_pool.platform.aws.security_groups` | Passthrough | Must have |
| STS Arbitrary Policies | Envelope - role policy bindings | Envelope | Must have |

### Authentication & Identity

| Feature | API Location | Type | Status |
|---|---|---|---|
| Identity Providers (all types) | `/clusters/{id}/identity_providers/` | Separate resource | Must have |
| Bring Your Own OIDC | Envelope field at cluster level | Envelope | Must have |
| External Authentication | `/clusters/{id}/external_auth/` | Separate resource | Must have |
| Break Glass Credentials | `/clusters/{id}/break_glass_credentials/` | Separate resource | Must have |

### Compute & Scaling

| Feature | API Location | Type | Status |
|---|---|---|---|
| Node Pools | `/clusters/{id}/nodepools/` | Core resource | Must have |
| Cluster Autoscaler | `hosted_cluster.autoscaling` | Passthrough | Must have |
| NodePool Autoscaling | `node_pool.auto_scaling` | Passthrough | Must have |
| Autoscaling to Zero | `node_pool.auto_scaling.min: 0` | Passthrough | Must have |
| Resource-based Autoscaling | Toggle-gated extension | Evaluate | Later |
| AutoNode (Karpenter) | `hosted_cluster.auto_node` + `/clusters/{id}/auto_nodepools/` | Passthrough + separate resource | Must have |
| AWS Capacity Reservations | `node_pool.platform.aws.placement.capacity_reservation` | Passthrough | Must have |
| Capacity Blocks for ML | `node_pool.platform.aws.placement.capacity_reservation.market_type: CapacityBlocks` | Passthrough | Must have |
| GPU Machine Pools | Instance type selection + machine_types inquiry | Passthrough | Must have |
| Multi-Architecture | `node_pool.arch: arm64` + `hosted_cluster.platform.aws.multi_arch` | Passthrough | Must have |
| Custom Worker Disk Size | `node_pool.platform.aws.root_volume.size` | Passthrough | Must have |
| Custom Root Volumes | `node_pool.platform.aws.root_volume` | Passthrough | Must have |
| Windows Node Pools | `node_pool.platform.aws.image_type: Windows` | Passthrough | Must have |
| AWS Outposts / Local Zones | Subnet configuration in node pool | Passthrough | Evaluate |
| Node Labels & Taints | `node_pool.node_labels` / `node_pool.taints` | Passthrough | Must have |
| Tuning Configs | `/clusters/{id}/tuning_configs/` | Separate resource | Must have |
| Kubelet Configs | `/clusters/{id}/kubelet_configs/` | Separate resource | Must have |
| Node Drain Grace Period | `node_pool.node_drain_timeout` | Passthrough | Must have |
| NodePool Upgrade Strategy | `node_pool.management` (Replace/InPlace, MaxSurge/MaxUnavailable) | Passthrough | Must have |

### Ingress & Load Balancing

| Feature | API Location | Type | Status |
|---|---|---|---|
| Multiple Ingress Controllers | `/clusters/{id}/ingresses/` | Separate resource | Must have |
| NLB vs Classic LB | `ingress.spec.load_balancer_type` | Ingress field | Must have |
| Private / Public Ingress | `ingress.spec.listening` | Ingress field | Must have |
| Custom Component Routes | `ingress.spec.component_routes` | Ingress field | Must have |
| Wildcard Policies | `ingress.spec.wildcard_policy` | Ingress field | Must have |
| Namespace Ownership | `ingress.spec.namespace_ownership_policy` | Ingress field | Must have |
| Excluded Namespaces / Selectors | `ingress.spec.excluded_namespaces` | Ingress field | Must have |
| Managed Ingress | Toggle-gated | Evaluate | Later |

### Observability & Logging

| Feature | API Location | Type | Status |
|---|---|---|---|
| Log Forwarding (CloudWatch) | `/clusters/{id}/log_forwarders/` | Separate resource | Must have |
| Log Forwarding (S3) | `/clusters/{id}/log_forwarders/` | Separate resource | Must have |
| Audit Log Forwarding | `log_forwarder.spec.log_types` | Field on LogForwarder | Must have |
| Cross-Account Audit | `log_forwarder.spec.cloudwatch.cross_account` | Field on LogForwarder | Must have |
| Day-1 Log Forwarding | `spec.log_forwarders` inline on ManagedCluster | Envelope field | Must have |
| User Workload Monitoring | `hosted_cluster.configuration` | Passthrough | Must have |
| Cluster Status | `/clusters/{id}/status` | Read-only endpoint | Must have |

### Cluster Lifecycle

| Feature | API Location | Type | Status |
|---|---|---|---|
| Control Plane Upgrades | `/clusters/{id}/upgrade_policies/` | Separate resource | Must have |
| NodePool Upgrades | `/clusters/{id}/nodepools/{id}/upgrade_policies/` | Separate resource | Must have |
| EUS Support | Version/channel metadata | Version resource | Must have |
| Y-stream Channels | `upgrade_policy.spec.channel` | Field on UpgradePolicy | Must have |
| Version Gates | `/version_gates/` + `/clusters/{id}/gate_agreements/` | Separate resources | Must have |
| Cluster Expiration | `spec.expiration_timestamp` | Envelope field | Must have |
| Cluster Backup | Envelope (day-1 inline + day-2 separate resource) | Envelope | Must have |

### Registry & Images

| Feature | API Location | Type | Status |
|---|---|---|---|
| Image Digest Mirror Sets | `hosted_cluster.image_content_sources` | Passthrough | Must have |
| Registry Allowlists | Platform-level + `/clusters/{id}/registry_config` | Separate resource | Must have |
| Blocked/Allowed/Insecure Registries | `/clusters/{id}/registry_config` | Separate resource | Must have |
| Additional Trusted CAs | `/clusters/{id}/registry_config` | Separate resource | Must have |
| Image Registry Enable/Disable | `/clusters/{id}/registry_config` | Separate resource | Must have |
| Zero-Egress Operator Mirrors | `hosted_cluster.image_content_sources` + toggle | Passthrough | Must have |

### Infrastructure & Config

| Feature | API Location | Type | Status |
|---|---|---|---|
| Custom DNS Domains | `hosted_cluster.dns.base_domain` | Passthrough | Must have |
| Custom AWS Tags | `hosted_cluster.platform.aws.resource_tags` | Passthrough | Must have |
| Custom NodePool Tags | `node_pool.platform.aws.resource_tags` | Passthrough | Must have |
| Cluster Properties | `spec.properties` | Envelope field | Must have |
| Manifests / SyncSets | `/clusters/{id}/manifests/` | Separate resource | Must have |
| External Config Labels | `/clusters/{id}/external_configuration/labels/` | Separate resource | Must have |

### Pre-provisioning Inquiries

| Feature | API Location | Notes |
|---|---|---|
| AWS VPC Inquiry | NOT in scope | Handled by AWS APIs directly |
| AWS Region Inquiry | NOT in scope | Handled by AWS APIs directly |
| AWS Machine Type Inquiry | `/machine_types/` | Platform-curated list |
| AWS Credential Validation | NOT in scope | SigV4 auth validates implicitly |
| AWS OIDC Thumbprint | NOT in scope | Platform manages OIDC |
| AWS STS Account Roles | NOT in scope | Handled by rosa CLI / IaC |
| AWS STS Credential Requests | NOT in scope | Handled by rosa CLI / IaC |
| AWS STS Policies | NOT in scope | Handled by rosa CLI / IaC |

**Rationale for removing inquiries**: In the regional model with SigV4 auth, the customer already has AWS credentials configured. VPC/region/credential inquiries are better served by AWS APIs directly. The rosa CLI can handle STS role setup as a client-side operation.

### Features NOT Applicable

| Feature | Reason |
|---|---|
| CCS (Customer Cloud Subscription) | All ROSA HCP regional clusters are CCS by design |
| AWS Infrastructure Access Roles | Replaced by IAM-based auth model |
| STS Support Jump Role | Different SRE access model (zero-operator) |
| Cluster Credentials (kubeadmin) | Break glass credentials replace this |
| Cluster Groups & Users | Managed through IDP/RBAC, not platform API |
| Cluster Metric Queries | Handled by observability stack, not platform API |
| Cluster Resources (Live) | Handled by observability stack |
| Install/Uninstall Logs | Available through observability, not dedicated endpoint |
| Inflight Checks | CLM adapters - reported via status conditions |
| Network Verification | CLM adapter - reported via status conditions |
| Trusted IPs | Replaced by CIDR block access control |
| Hypershift Info | Internal detail, not customer-facing |
| Storage/LB Quota Values | AWS quotas, not platform concern |
| Deleted Clusters Query | TBD - may add later for audit |
| Technology Previews | Platform-level config, not API |
| Product Minimal Versions | Handled by versions endpoint |
| Limited Support Reasons | SRE tooling, not customer API |
| Pending Delete Cluster | Handled by delete_protection + expiration |
| End-of-Life Grace Period | Platform policy, not per-cluster API |

---

## CLM Integration

The ROSA Regional Platform API wraps the CLM API with these transformations:

```
Customer Request                    CLM API
─────────────────                   ───────
POST /clusters                  →   POST /api/hyperfleet/v1/clusters
  ManagedCluster.spec           →     Cluster.spec (contains HostedCluster CR + envelope)
  ManagedCluster.metadata       →     Cluster.name, Cluster.labels

GET /clusters/{id}              →   GET /api/hyperfleet/v1/clusters/{id}
  ManagedCluster.status         ←     Cluster.status.conditions (aggregated from adapters)

POST /clusters/{id}/nodepools   →   POST /api/hyperfleet/v1/clusters/{id}/nodepools
  NodePool.spec                 →     NodePool.spec (contains NodePool CR + envelope)

GET /clusters/{id}/nodepools    →   GET /api/hyperfleet/v1/clusters/{id}/nodepools
```

The CLM spec is a flexible `map[string]interface{}` - we populate it with:

```json
{
  "envelope": {
    "delete_protection": {...},
    "expiration_timestamp": "...",
    "properties": {...},
    "log_forwarders": [...]
  },
  "hosted_cluster": {
    // Full HostedCluster CR spec
  }
}
```

CLM adapters (validation, DNS, provisioning) read the spec and act on it. The platform API reconstructs the ManagedCluster response from CLM's stored spec + aggregated status.

## Design Decisions

1. **Karpenter NodePools**: **Separate endpoint** (`/clusters/{id}/auto_nodepools/`). Karpenter NodePools have a fundamentally different spec (NodeClass, requirements, limits, disruption policies) that doesn't map to the traditional NodePool spec.

2. **Day-1 Log Forwarding**: **Support both**. Inline `log_forwarders` in ManagedCluster envelope spec for day-1, plus `/clusters/{id}/log_forwarders/` as a separate resource for day-2 management.

3. **PrivateLink model**: **Passthrough via HyperShift fields**. PrivateLink is customer-configured (not implicit). In HyperShift, it maps to `endpoint_access: Private|PublicAndPrivate` + `additional_allowed_principals`. Day-1 is covered by passthrough. Day-2 principal management needs `/clusters/{id}/private_link_principals/` sub-resource.

4. **DNS domain assignment**: **Platform assigns** the kube API domain. Customer does not specify `base_domain` for the API server; the platform generates it.

5. **STS role format**: **Use HyperShift `roles_ref` passthrough** (7 fixed operator IRSA roles). The current ROSA STS model is more complex (installer role, support role, instance profiles, permission boundaries, managed policies flag) but most of those are unnecessary in the HyperShift model:
   - No installer role needed (HyperShift bootstraps via OIDC)
   - No support role (different SRE access model in regional architecture)
   - No EC2 instance profiles (all OIDC-based in HyperShift)
   - Permission boundaries: not in HyperShift RolesRef, may need envelope field if required
   - `RolePolicyBindings` (arbitrary policies): needs envelope field if feature is required
   - HyperShift RolesRef fields: `IngressARN`, `ImageRegistryARN`, `StorageARN`, `NetworkARN`, `KubeCloudControllerARN`, `NodePoolManagementARN`, `ControlPlaneOperatorARN`

6. **HTPasswd user management**: **Keep as sub-resource** of IDP (`/clusters/{id}/identity_providers/{id}/htpasswd_users/`) for parity, including bulk import.

7. **User workload monitoring**: **Passthrough**. `disable_user_workload_monitoring` is part of HostedCluster configuration, so it goes through `hosted_cluster.configuration`.

8. **Cluster backup configuration**: **Support both**, like log forwarding. Inline in ManagedCluster envelope spec for day-1, plus separate resource for day-2 management.

9. **IMDSv2 enforcement**: **Passthrough**. If HyperShift supports it (via annotation or spec field), pass it through. If not, contribute upstream and then passthrough.

10. **Transparent forward proxies**: **Keep for now**. Transparent forward proxies are a customer network topology concern, not specific to the regional architecture. Customers may still have transparent proxies in their VPCs.

11. **RolePolicyBindings**: **Yes, support as envelope field**. HyperShift RolesRef doesn't support arbitrary policy bindings, so this is an envelope concern. The platform will manage policy attachments outside of HyperShift.

12. **Permission Boundaries**: **Yes, support as envelope field**. Same rationale - HyperShift doesn't have this concept, so the platform manages it as an envelope field and applies boundaries during role setup.

13. **Cluster backup day-2 endpoint**: **Singleton** at `/clusters/{id}/backup_config`. Note: may evolve to a collection if we need multiple backup schedules or backup targets in the future.

14. **PrivateLink principals sync**: **Passthrough**. `additional_allowed_principals` is a field on HyperShift's `AWSPlatformSpec`. Day-2 principal changes update this field on the HostedCluster CR spec via CLM. The `/private_link_principals/` sub-resource is a convenience API that reads/writes to the same passthrough field.

15. **Version and MachineType data source**: **GitOps-managed config**. Available versions and machine types are sourced from GitOps-managed configuration in the regional platform repository, not from AWS APIs or a central registry.
