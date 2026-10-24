# Containers within ROSA Seaplane (Region). MC and Customer Hosted
# Cluster are kept coarse-grained; RC's internals are modelled one
# level deeper, as Components, since RC is the container this model
# currently drills into.

rc = container "Regional Cluster (RC)" "The region's always-on control plane: exposes the customer-facing API, owns lifecycle state for every hosted cluster, and publishes desired configuration for the rest of the region to consume." {
    platformApi  = component "Platform API" "Stateless, customer-facing REST API behind API Gateway. Extracts caller identity from SigV4 requests, applies per-account rate limiting (backed by a shared ElastiCache Valkey counter store), and reads/writes cluster lifecycle state."
    operator     = component "Seaplane Operator" "Reconciles cluster-lifecycle custom resources against desired state. Writes desired cluster and add-on configuration to, and reads reported status from, the Desire DynamoDB tables that each MC's kube-applier polls."
    seaplaneDb   = component "seaplane-db (PostgreSQL)" "The sole state store for cluster lifecycle resources, shared by Platform API and the Operator." "Database"
    desireTables = component "Desire DynamoDB Tables" "Cross-account tables, in the RC account, that bridge the desire loop between the Operator and each MC's kube-applier — the only desired-state channel between RC and MC; there is no direct network path." "Database"
    argoCdRc     = component "ArgoCD (RC)" "GitOps controller that self-manages RC: deploys and updates RC's own components, including itself, from pinned image SHAs and Helm charts in the Config Git Repo."
    alertmanager = component "Alertmanager" "Routes firing Prometheus alerts (via Thanos Ruler) to receivers: critical alerts page PagerDuty directly, while a parallel SNS fan-out route lets any number of subscribers receive alerts independently."

    argoCdRc -> platformApi "Deploys and manages the lifecycle of"
    argoCdRc -> operator "Deploys and manages the lifecycle of"
    platformApi -> seaplaneDb "Reads and writes cluster lifecycle state in"
    operator -> seaplaneDb "Reconciles cluster lifecycle state in"
    operator -> desireTables "Writes desired cluster and add-on configuration to, and reads reported status back from"

    # ZOA (Zero Operator Access) components. Only the ZOA-relevant pieces
    # are modelled here and on `mc` below — neither container is fully
    # decomposed yet outside of this slice.
    zoaAccessLambda = component "ZOA Access Lambda" "Session lifecycle for ZOA: starts, lists, joins, and terminates audited boundary sessions; launches the Boundary task (cross-account for MC targets) and records sessions in the shared data store. No VPC." "Serverless"
    zoaApiLambda     = component "ZOA API Lambda" "Executes Trusted Actions dispatched from inside a Boundary session: validates the request, then impersonates a scoped, ephemeral Kubernetes ServiceAccount or assumes a scoped IAM role, and records execution/audit output." "Serverless"
    zoaWorkerLambda  = component "ZOA Worker Lambda" "Scheduled reconciler: processes async Trusted Action executions, garbage-collects ephemeral RBAC, and reaps idle or expired boundary sessions." "Serverless"
    zoaBoundary      = component "ZOA Boundary" "Ephemeral ECS Fargate task an SRE connects to via SSM before running any Trusted Action — the audited shell everything else happens inside. No persistent disk; torn down on session end." "Serverless"
    zoaDataStore     = component "ZOA Data Store" "Shared, RC-hosted state for ZOA: DynamoDB (sessions, executions, audit) and S3 (Trusted Action output/logs). Read and written cross-account by MC's ZOA components via resource-based policies." "Database"
    kubeApiServer    = component "Kubernetes API Server" "The EKS control plane's API for RC — the execution target Trusted Actions act against via an impersonated, ephemeral ServiceAccount." "EKS"

    zoaAccessLambda -> zoaDataStore "Writes and updates boundary session records in"
    zoaAccessLambda -> zoaBoundary "Launches and vends scoped ECS Exec credentials for" "ecs:RunTask"
    zoaBoundary -> zoaApiLambda "Runs Trusted Actions and reads audit from" "zoa run, HTTPS / AWS SigV4 (ECS task role)"
    zoaApiLambda -> zoaDataStore "Records execution and audit entries in, uploads Trusted Action output/logs to"
    zoaApiLambda -> kubeApiServer "Executes Trusted Actions against" "impersonated Kubernetes ServiceAccount, scoped ephemeral RBAC"
    zoaWorkerLambda -> zoaDataStore "Reconciles async executions, runs garbage collection, and reaps idle/expired boundary sessions in"
}
mc = container "Management Cluster (MC)" "Dynamically-provisioned, isolated-account cluster hosting the control planes of multiple customer hosted clusters; pulls its desired configuration rather than being directly reachable from RC." {
    kubeApplier        = component "kube-applier" "Leader-elected Deployment, one per MC, that bridges RC's declarative desire state to this cluster: polls the Desire DynamoDB tables (in the RC account) via a two-speed GSI poll, applies the corresponding resources to MC's own Kubernetes API Server via Server-Side Apply, and writes status back — the only desired-state channel between RC and MC; there is no direct network path."
    hyperShiftOperator = component "HyperShift Operator" "Watches HostedCluster and NodePool custom resources on MC's own Kubernetes API Server and reconciles each into the running control-plane components for one customer's Hosted Cluster, isolated per customer on MC's own compute."
    argoCdMc           = component "ArgoCD (MC)" "GitOps controller that self-manages MC: deploys and updates MC's own components, including itself, from pinned image SHAs and Helm charts in the Config Git Repo."

    # ZOA slice (Zero Operator Access), symmetric with RC's — neither
    # container is decomposed beyond this plus the components above.
    zoaBoundary     = component "ZOA Boundary" "Ephemeral ECS Fargate task an SRE connects to via SSM before running any Trusted Action, symmetric with RC's — the audited shell everything else happens inside. No persistent disk; torn down on session end." "Serverless"
    zoaApiLambda    = component "ZOA API Lambda" "Executes Trusted Actions dispatched from inside this MC's Boundary session: validates the request, then impersonates a scoped, ephemeral Kubernetes ServiceAccount or assumes a scoped IAM role, and records execution/audit output (cross-account, in RC's data store)." "Serverless"
    zoaWorkerLambda = component "ZOA Worker Lambda" "Scheduled reconciler for this MC: processes async Trusted Action executions, garbage-collects ephemeral RBAC, and reaps idle or expired boundary sessions (cross-account, in RC's data store)." "Serverless"
    kubeApiServer   = component "Kubernetes API Server" "The EKS control plane's API for this MC — the target kube-applier applies desired resources to, HyperShift Operator reconciles HostedCluster/NodePool CRs against, and Trusted Actions execute against via an impersonated, ephemeral ServiceAccount." "EKS"

    argoCdMc -> kubeApplier "Deploys and manages the lifecycle of"
    argoCdMc -> hyperShiftOperator "Deploys and manages the lifecycle of"
    kubeApplier -> kubeApiServer "Applies, deletes, and watches Kubernetes resources on, via Server-Side Apply"
    hyperShiftOperator -> kubeApiServer "Watches HostedCluster and NodePool custom resources in, and creates the hosted control-plane workloads via"
    zoaBoundary -> zoaApiLambda "Runs Trusted Actions and reads audit from" "zoa run, HTTPS / AWS SigV4 (ECS task role)"
    zoaApiLambda -> kubeApiServer "Executes Trusted Actions against" "impersonated Kubernetes ServiceAccount, scoped ephemeral RBAC"
}
customerHostedCluster = container "Customer Hosted Cluster" "A customer's ROSA HCP cluster: a dedicated control plane running inside a Management Cluster, with worker nodes in the customer's own AWS account."
