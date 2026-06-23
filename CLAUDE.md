# Rosa Regional Platform - Claude Instructions

## Project Overview

The **ROSA Regional Platform** is a strategic redesign of Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes (HCP). This project transforms ROSA from a globally-centralized management model to a **regionally-distributed architecture** where each AWS region operates independently with its own control plane infrastructure.

**Key Goals:**

- **Regional Independence**: Each region operates autonomously with its own cluster lifecycle management service to reduce global dependencies
- **Operational Simplicity**: GitOps-driven deployment with zero-operator access model
- **Modern Cloud-Native Architecture**: Built on AWS services (EKS, RDS, API Gateway)
- **Disaster Recovery**: Declarative state management with cross-region backups

## Architecture Overview

### Three-Layer Regional Architecture

1. **Regional Cluster (RC)** - EKS-based cluster running core services:
   - Platform API (customer-facing with AWS IAM auth)
   - CLM (Cluster Lifecycle Manager) - single source of truth
   - Maestro - MQTT-based configuration distribution
   - ArgoCD - GitOps deployment
   - ZOA (Zero Operator Access) - mediated operational access via Trusted Actions

2. **Management Clusters (MC)** - EKS clusters hosting customer control planes:
   - Run HyperShift operators hosting multiple customer control planes
   - Dynamically provisioned and scaled per region
   - Private Kubernetes APIs with no network path to RC (ideal state)

3. **Customer Hosted Clusters** - ROSA HCP clusters with control planes in MC

### Zero Operator Access (ZOA)

ZOA is the FedRAMP-compliant operational access framework. Operators execute pre-approved Trusted Actions via a mediated API instead of using kubectl, SSH, or IAM role assumption. Every action is auditable (DynamoDB), artifact-producing (S3, KMS-encrypted), time-bounded, and least-privileged (per-execution RBAC). Trusted Action templates are defined as YAML in the platform repo and dispatched to target clusters via Maestro ManifestWorks. See `docs/design/zoa-architecture.md`, `docs/design/zoa-trusted-actions.md`, and `docs/design/zoa-security-model.md`.

## Key Technologies

- **Compute**: Amazon EKS (Regional + Management Clusters)
- **Networking**: VPC, API Gateway (regional), VPC Link v2, ALBs
- **Storage**: Amazon RDS (CLM state), EBS volumes
- **Identity**: AWS IAM for authentication and authorization
- **Infrastructure**: Terraform modules with GitOps patterns
- **CI/CD**: ArgoCD (apps), AWS CodePipeline (infrastructure pipelines)
- **Operational Access**: ZOA Trusted Actions (DynamoDB, S3, KMS, EKS Pod Identity)
- **Messaging**: Maestro (MQTT-based resource distribution)
- **Languages**: Go (primary backend), Shell scripting
- **Container Orchestration**: Kubernetes via EKS

## Project Tracking

Work for the ROSA Regional Platform is tracked in Jira under two parent Outcomes:

- **[HPSTRAT-62](https://redhat.atlassian.net/browse/HPSTRAT-62)** ("Red Hat Cloud Data Sovereignty"): Feature-driven work covering the regional platform build-out (architecture, infrastructure, services, tooling).
- **[HPSTRAT-11](https://redhat.atlassian.net/browse/HPSTRAT-11)** ("FedRAMP Moderate Technical Delivery"): Compliance work covering FedRAMP security controls, audit requirements, and certification readiness.

Each Outcome contains **Feature** issues in the **ROSA** project representing milestones, identified by the `[Regionality]` prefix in their summary (e.g. "[Regionality] Milestone 5 - CLM Integration").

Day-to-day engineering tasks (epics, stories, bugs) live in the **ROSAENG** project under the **"ROSA Regionality Platform"** component.

The portfolio view JQL combines both: the ROSAENG component filter plus the ROSA `[Regionality]` milestone Features by key.

## Development Guidelines

### Agent Usage

- **ALWAYS use the architect agent** for changes to:
  - `docs/design/`
  - Any architectural decisions or patterns
- **Use adversary agent** for security review of code changes (supply chain, infrastructure, application security)
- **Use code-reviewer agent** for code quality review
- **Use ci-troubleshooter agent** for diagnosing CI/CD failures
- **Use documentation-updater agent** for reviewing documentation freshness

### Architecture Patterns

- **GitOps First**: ArgoCD for cluster configuration management, infrastructure via Terraform
- **Private-by-Default**: EKS clusters use fully private architecture with ECS bootstrap
- **Declarative State**: CLM maintains single source of truth for all cluster state
- **Event-Driven**: Maestro handles CLM ↔ MC communication for configuration distribution
- **Regional Isolation**: Each region operates independently with minimal cross-region dependencies
- **Explicit Feature Flags**: Optional or environment-specific infrastructure (e.g., CloudTrail, PagerDuty, resources with per-account limits) should be gated behind `enable_*` configuration flags. Avoid patterns like checking against the environment's name to change behavior or functionality.
  - Feature flags should default to what keeps the best developer experience — focus on the lowest barrier to getting a new region started. We'd rather have verbose production configs than require developers to understand every flag just to get going.

### Key Design Decisions

- **Bootstrap Strategy**: Use ECS Fargate for private EKS cluster bootstrap (see `docs/design/fully-private-eks-bootstrap.md`)
- **No Public APIs**: All EKS clusters are fully private with VPC-only access
- **ArgoCD Self-Management**: Clusters manage their own ArgoCD installations via GitOps

### Repository Structure

```
terraform/
├── modules/eks-cluster/              # EKS with private bootstrap
├── modules/ecs-bootstrap/            # Fargate bootstrap tasks
├── modules/zoa/                      # ZOA infrastructure (DynamoDB, S3, KMS, IAM)
├── modules/zoa-job-pod-identity/     # Per-cluster EKS Pod Identity for ZOA jobs
└── config/                           # Cluster configuration templates

argocd/
├── config/                   # Live Helm chart configurations
│   ├── management-cluster/   # MC application templates
│   ├── regional-cluster/     # RC application templates
│   └── shared/              # Shared configurations (incl. zoa-jobs chart)
└── README.md

images/
└── zoa-tools/                # ZOA tools container image (aws-cli, kubectl, jq)

.ambient/
├── ci-analyser-agent/        # Nightly CI failure diagnosis & fix PRs (rrp-bot)
└── documentation-update-agent/ # Daily doc staleness detection & update PRs (rrp-bot)

docs/
├── README.md                 # Architecture overview
├── FAQ.md                   # Architecture decisions Q&A
├── design/                  # ADRs (Architecture Decision Records)
├── environment-provisioning.md
├── hostedcluster-provisioning.md  # User-facing: create & access a hosted cluster
├── hostedcluster-teardown.md     # Admin-only: manual teardown & force cleanup
├── development-environment.md
├── adding-alerting-rules.md  # Platform alerting and recording rules
├── adding-component-pre-merge.md
└── sop/                     # Standard operating procedures
```

### Development Workflow

#### For Infrastructure Changes

1. Update Terraform modules in `terraform/modules/`
2. Run `make pre-push` before committing or pushing — this is the all-in-one command that runs
   `terraform-fmt`, `check-docs`, `check-rendered-files`, `helm-lint`, and `terraform-validate`,
   matching the full CI suite. Individual targets (e.g. `make terraform-fmt`) can still be used
   for targeted runs.
3. Ensure architect agent reviews any architectural changes

#### For Application Changes

1. Update ArgoCD configurations in `argocd/`
2. Follow GitOps patterns - ArgoCD will sync changes
3. Test in development region first
4. Run `make pre-push` before pushing — `check-docs` (prettier markdown) and other non-Terraform
   checks apply to all change types

#### For New Regions

1. Add region config to `config/<environment>/` and render with `uv run scripts/render.py`
2. Bootstrap the central pipeline (see `docs/environment-provisioning.md`)
3. ArgoCD bootstrap handles core service deployment
4. Management Clusters auto-provision as needed
5. Run `make pre-push` before pushing to validate all rendered files and documentation

#### Ephemeral Environments

See [`docs/development-environment.md`](docs/development-environment.md) for full usage — provisioning, resync, E2E, teardown, and port forwarding.

### Security Guidelines

- **AWS IAM Only**: Use AWS IAM for all authentication/authorization
- **Private Networking**: No public endpoints except regional API Gateway
- **Least Privilege**: Follow AWS IAM best practices for service roles
- **Encryption at Rest**: KMS-encrypted EKS secrets, RDS, and EBS volumes
- **Network Segmentation**: Dedicated security groups for VPC endpoints and services
- **High Availability**: Multi-AZ NAT Gateways eliminate single points of failure
- **Break-Glass Access**: Use ephemeral containers for emergency access only

### Formatting

- **Markdown**: All markdown files must be formatted with `prettier`. Run `npx prettier --write '**/*.md'` before committing markdown changes.
- **Diagrams**: Always use Mermaid for diagrams in markdown files, never ASCII art.

### Testing and Validation

- **Pre-push (required)**: Run `make pre-push` before committing or pushing. This single command
  runs the full CI validation suite — `terraform-fmt`, `check-docs` (prettier markdown),
  `check-rendered-files`, `helm-lint`, and `terraform-validate` — matching exactly what CI will
  enforce. Skipping this step is how formatting and lint failures reach CI (e.g. PR #364).
- **Terraform Validation**: Always run `terraform validate` and `terraform plan`
- **Format Check**: `make terraform-fmt` (also run automatically by `make pre-push`)
- **ArgoCD Health**: Verify applications sync successfully
- **Security Review**: Use architect agent for security-sensitive changes

### Alerting Rules

Platform alerting and recording rules are defined as PrometheusRule CRs in the `alerting-rules` chart (`argocd/config/regional-cluster/alerting-rules/templates/`). Rules are evaluated by Thanos Ruler against Thanos Query. See [docs/adding-alerting-rules.md](docs/adding-alerting-rules.md) for a developer guide on adding new rules, including the error budget burn rate pattern used for SLA alerts.

### Important Files and Patterns

- `Makefile` - Standardized provisioning commands
- `scripts/bootstrap-argocd.sh` - ECS Fargate bootstrap script
- `argocd/config/shared/argocd/` - ArgoCD self-management Helm chart
- Design decisions follow ADR format in `docs/design/`
