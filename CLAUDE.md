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
   - Tekton - infrastructure provisioning pipelines

2. **Management Clusters (MC)** - EKS clusters hosting customer control planes:
   - Run HyperShift operators hosting multiple customer control planes
   - Dynamically provisioned and scaled per region
   - Private Kubernetes APIs with no network path to RC (ideal state)

3. **Customer Hosted Clusters** - ROSA HCP clusters with control planes in MC

## Key Technologies

- **Compute**: Amazon EKS (Regional + Management Clusters)
- **Networking**: VPC, API Gateway (regional), VPC Link v2, ALBs
- **Storage**: Amazon RDS (CLM state), EBS volumes
- **Identity**: AWS IAM for authentication and authorization
- **Infrastructure**: Terraform modules with GitOps patterns
- **CI/CD**: ArgoCD (apps), Tekton (infrastructure pipelines)
- **Messaging**: Maestro (MQTT-based resource distribution)
- **Languages**: Go (primary backend), Shell scripting
- **Container Orchestration**: Kubernetes via EKS

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

### Key Design Decisions

- **Bootstrap Strategy**: Use ECS Fargate for private EKS cluster bootstrap (see `docs/design/fully-private-eks-bootstrap.md`)
- **No Public APIs**: All EKS clusters are fully private with VPC-only access
- **ArgoCD Self-Management**: Clusters manage their own ArgoCD installations via GitOps

### Repository Structure

```
terraform/
├── modules/eks-cluster/        # EKS with private bootstrap
├── modules/ecs-bootstrap/      # Fargate bootstrap tasks
└── config/                    # Cluster configuration templates

argocd/
├── config/                   # Live Helm chart configurations
│   ├── management-cluster/   # MC application templates
│   ├── regional-cluster/     # RC application templates
│   └── shared/              # Shared configurations
└── README.md

docs/
├── README.md                 # Architecture overview
├── FAQ.md                   # Architecture decisions Q&A
├── design/                  # ADRs (Architecture Decision Records)
├── environment-provisioning.md
├── hostedcluster-provisioning.md
├── development-environment.md
├── adding-component-pre-merge.md
└── sop/                     # Standard operating procedures
```

### Development Workflow

#### For Infrastructure Changes

1. Update Terraform modules in `terraform/modules/`
2. Use `make terraform-fmt` and lint jobs for sanitization
3. For testing: use `make ephemeral-provision` for ephemeral dev environments, or run `terraform init && terraform apply` directly in the relevant `terraform/config/` directory
4. Ensure architect agent reviews any architectural changes

#### For Application Changes

1. Update ArgoCD configurations in `argocd/`
2. Follow GitOps patterns - ArgoCD will sync changes
3. Test in development region first

#### For New Regions

1. Add region config to `config/<environment>/` and render with `uv run scripts/render.py`
2. Bootstrap the central pipeline (see `docs/environment-provisioning.md`)
3. ArgoCD bootstrap handles core service deployment
4. Management Clusters auto-provision as needed

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

- **Terraform Validation**: Always run `terraform validate` and `terraform plan`
- **Format Check**: Use `make terraform-fmt` before committing
- **ArgoCD Health**: Verify applications sync successfully
- **Security Review**: Use architect agent for security-sensitive changes

### Important Files and Patterns

- `Makefile` - Standardized provisioning commands
- `bootstrap-argocd.sh` - ECS Fargate bootstrap script
- `argocd/config/shared/argocd/` - ArgoCD self-management Helm chart
- Design decisions follow ADR format in `docs/design/`

Include AGENTS.md
