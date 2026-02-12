# Terraform Configurations

## CI/CD Pipelines

```mermaid
flowchart LR
    subgraph events ["Events"]
        direction TB
        TF["terraform apply<br/>bootstrap-pipeline/"]
        G1["git push<br/>deploy/**"]
        G2["git push<br/>deploy/‹env›/‹region›/**"]
        G3["git push<br/>deploy/‹env›/‹region›/terraform/management/**"]
    end

    subgraph pipelines ["CodePipelines"]
        direction TB
        PP["pipeline-provisioner/"]
        RC_PIPE["pipeline-regional-cluster/"]
        MC_PIPE["pipeline-management-cluster/"]
    end

    TF -->|one-time setup| PP
    G1 -->|triggers| PP
    PP -->|"reads terraform/regional.json<br/>creates pipeline"| RC_PIPE
    PP -->|"reads terraform/management/*.json<br/>creates pipeline"| MC_PIPE
    G2 -->|triggers| RC_PIPE
    G3 -->|triggers| MC_PIPE

    style TF fill:#fff3e0,stroke:#e6a23c
    style G1 fill:#fff3e0,stroke:#e6a23c
    style G2 fill:#fff3e0,stroke:#e6a23c
    style G3 fill:#fff3e0,stroke:#e6a23c
    style PP fill:#e0f0ff,stroke:#4a90d9
    style RC_PIPE fill:#e0f0ff,stroke:#4a90d9
    style MC_PIPE fill:#e0f0ff,stroke:#4a90d9
```

### `bootstrap-pipeline/`

Seeds the initial CodePipeline that watches the `deploy/` directory in the repository. When cluster configuration files are added or updated, it triggers the pipeline provisioner to dynamically create the corresponding CodePipelines.

Cluster configurations follow this directory structure:

- `deploy/<env>/<region_alias>/terraform/regional.json` — regional cluster pipelines
- `deploy/<env>/<region_alias>/terraform/management/<cluster>.json` — management cluster pipelines

After deploying, the GitHub CodeStar connection must be authorized manually:

1. Navigate to AWS Console > Developer Tools > Connections
2. Select the pending connection and authorize with GitHub

### `pipeline-provisioner/`

Meta-pipeline that dynamically creates per-cluster CodePipelines when regional or management cluster JSON files are committed to `deploy/`.

### `pipeline-regional-cluster/`

Three-stage CodePipeline (validate → deploy → bootstrap) for provisioning a regional cluster. Created dynamically by the pipeline provisioner.

### `pipeline-management-cluster/`

Three-stage CodePipeline (validate → deploy → bootstrap) for provisioning a management cluster. Created dynamically by the pipeline provisioner.

## Cluster Infrastructure

### `regional-cluster/`

Provisions the full regional cluster stack: EKS, VPC, API Gateway, Maestro IoT broker, RDS, authorization (DynamoDB + Pod Identity), ECS bootstrap, and optional bastion.

### `management-cluster/`

Provisions a management cluster: private EKS (1–2 nodes), ECS bootstrap, Maestro agent, and optional bastion. Hosts customer control planes.

### `maestro-agent-iot-provisioning/`

Standalone wrapper around the `maestro-agent-iot-provisioning` module for pipeline-based IoT provisioning. Provisions AWS IoT Core certificates and policies for Maestro agents in management clusters.

Usage:

1. Generate `terraform.tfvars` with cluster-specific values
2. Run `terraform init && terraform apply`
3. Extract certificate data: `terraform output -json certificate_data`
4. Transfer to management account Secrets Manager
