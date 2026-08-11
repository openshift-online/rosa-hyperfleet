# Karpenter Lifecycle and ArgoCD Ownership

Reference for engineers working on RC or MC cluster compute provisioning. Covers how Karpenter is
installed, adopted by ArgoCD, and how it differs from EKS Auto Mode.

## Bootstrap sequence

EKS clusters use fully private APIs (no public endpoint), so Terraform cannot reach the cluster to
install software directly. An ECS Fargate task runs in the cluster's VPC and performs first-boot
installation.

```mermaid
sequenceDiagram
    participant TF as Terraform
    participant ECS as ECS Bootstrap Task
    participant K8s as EKS Cluster
    participant ARGO as ArgoCD

    TF->>K8s: Provision EKS cluster
    TF->>K8s: Create karpenter-bootstrap node group (2× t3.large, CriticalAddonsOnly:NoSchedule)
    TF->>K8s: Install EKS addons (vpc-cni, coredns, metrics-server, pod-identity)
    TF->>ECS: Start bootstrap task

    ECS->>K8s: Wait for coredns + metrics-server addon-active
    ECS->>K8s: helm install argocd (argocd/config/shared/argocd, --wait --timeout 10m)
    ECS->>K8s: kubectl apply cluster identity secret (with karpenter_controller_role_arn annotation)
    ECS->>K8s: kubectl apply root Application (points to repo argocd/config/<cluster_type>)
    ECS-->>ECS: Exit

    ARGO->>K8s: Sync all Applications concurrently<br/>(karpenter, eks-nodepool, everything else)
    Note over ARGO,K8s: eks-nodepool's EC2NodeClass/NodePool apply may fail<br/>until Karpenter's CRDs exist
    ARGO->>K8s: retry with backoff (selfHeal, retry.limit=-1)
    Note over ARGO,K8s: eks-nodepool succeeds once Karpenter CRDs are registered;<br/>Karpenter begins provisioning workload nodes
```

## Node groups

| Node group                         | Type            | Size                                   | Taint                           | Purpose                                                            |
| ---------------------------------- | --------------- | -------------------------------------- | ------------------------------- | ------------------------------------------------------------------ |
| `<cluster-id>-karpenter-bootstrap` | EKS managed     | 2× t3.large, fixed (min=max=desired=2) | `CriticalAddonsOnly:NoSchedule` | Runs ArgoCD + Karpenter controller for the lifetime of the cluster |
| Karpenter-provisioned              | EC2 (Karpenter) | Defined by NodePool                    | None                            | Runs all other workloads                                           |

The bootstrap node group is **not scaled by Karpenter**. It is declared in Terraform with fixed
capacity and persists indefinitely. The `CriticalAddonsOnly:NoSchedule` taint prevents workload pods
from landing on infrastructure nodes; ArgoCD and Karpenter explicitly tolerate it.

## ArgoCD ownership of Karpenter

After bootstrap, ArgoCD fully owns Karpenter. There is no ongoing ECS involvement.

**Ordering**: all Applications sync concurrently — there is no sync-wave ordering between
`karpenter` and `eks-nodepool`. Per the project's eventual-consistency model (see
`config/templates/argocd-bootstrap/applicationset.yaml.j2`'s `syncPolicy`), `eks-nodepool`'s
`EC2NodeClass`/`NodePool` apply may fail on first sync if Karpenter's CRDs aren't registered yet.
`selfHeal: true` and `retry.limit: -1` with exponential backoff mean ArgoCD keeps retrying until
the CRDs exist and the apply succeeds — no manual intervention or ordering annotation required.

**Namespace override**: the `karpenter` Application deploys to `kube-system` (not a `karpenter`
namespace). All other applications deploy to a namespace matching their directory basename.

**ApplicationSet injection** — the following values are injected into the Karpenter Application
from cluster identity secret annotations at sync time:

```yaml
karpenter:
  settings:
    clusterName: "{{ .metadata.labels.cluster_name }}"
    interruptionQueue: "{{ .metadata.labels.cluster_name }}-karpenter"
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "{{ .metadata.annotations.karpenter_controller_role_arn }}"
```

The `karpenter_controller_role_arn` annotation is written to the cluster identity secret by the ECS
bootstrap task (sourced from a Terraform output via an ECS environment variable).

**Karpenter chart** (`argocd/config/{management-cluster,regional-cluster}/karpenter/Chart.yaml`):

```yaml
dependencies:
  - name: karpenter
    version: 1.14.0
    repository: oci://public.ecr.aws/karpenter
```

To upgrade Karpenter, update the version here and run `make pre-push`. ArgoCD will apply the
upgrade on the next sync.

## SQS interruption queue

Each cluster has an SQS queue named `<cluster-name>-karpenter` that handles:

- **Spot interruption notices** (2-minute warning before reclaim)
- **On-Demand scheduled maintenance events** (AWS Health events, scheduled stops/reboots)
- **Instance rebalance recommendations**

The queue name is injected via ApplicationSet (`interruptionQueue` setting above). The Karpenter
controller IAM role has permission to read from this queue.

## Auto Mode vs self-managed Karpenter

| Behavior                  | EKS Auto Mode (removed)                             | Self-managed Karpenter (current)                                                                                                 |
| ------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **Node provisioning**     | AWS-managed; compute optimized by default           | Operator-defined `NodePool` and `EC2NodeClass` CRs                                                                               |
| **Instance selection**    | AWS selects instance family automatically           | Declared in `NodePool` requirements; engineers control family/arch/capacity type                                                 |
| **Node images**           | AWS manages AMI selection and updates               | Bottlerocket AMI alias `bottlerocket@v1.64.0` (RHEL with FIPS mode planned); configured on both MC and RC EC2NodeClass resources |
| **GitOps ownership**      | No Karpenter Application; AWS reconciles internally | `argocd/config/<cluster-type>/karpenter/` chart, ArgoCD-managed                                                                  |
| **Lifecycle management**  | Auto Mode lifecycle controller (AWS)                | Karpenter `NodePool` disruption budget and expiry settings                                                                       |
| **Interruption handling** | AWS-managed                                         | SQS queue + Karpenter interruption handler                                                                                       |
| **Version upgrades**      | EKS console / API flag                              | Update `Chart.yaml` version → ArgoCD syncs                                                                                       |
| **Drift detection**       | None (AWS owns config)                              | ArgoCD detects drift; selfHeal=true corrects it                                                                                  |
| **Kubernetes API**        | Cluster API blocks Auto Mode specific operations    | Standard Karpenter CRs; no special API restrictions                                                                              |
| **Bootstrap dependency**  | Auto Mode enabled at cluster creation; no ECS step  | ECS task installs ArgoCD; ArgoCD installs Karpenter, retries dependents until CRDs are ready                                     |
| **Bootstrap node group**  | No bootstrap group required                         | `<cluster-id>-karpenter-bootstrap` node group required (ArgoCD + Karpenter must run before workload nodes exist)                 |
