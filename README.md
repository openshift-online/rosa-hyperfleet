# rosa-regional-platform

## Repository Structure

```
rosa-regional-platform/
├── argocd/
│   └── config/                       # Live Helm chart configurations
│       ├── applicationset/           # ApplicationSet templates
│       ├── management-cluster/       # Management cluster application templates
│       ├── regional-cluster/         # Regional cluster application templates
│       └── shared/                   # Shared configurations (ArgoCD, etc.)
├── ci/                               # CI automation (janitor, etc.)
├── deploy/                           # Per-environment deployment configs
├── docs/                             # Design documents and presentations
├── hack/                             # Developer utility scripts
├── scripts/                          # Dev and pipeline scripts
└── terraform/
    ├── config/                       # Terraform root configurations
    └── modules/                      # Reusable Terraform modules
```

## Getting Started

### Cluster Provisioning

Quick start (regional cluster):
```bash
# One-time setup: Copy and edit configurations
cp terraform/config/regional-cluster/terraform.tfvars.example \
   terraform/config/regional-cluster/terraform.tfvars

# Provision complete regional cluster environment based on the .tfvars file
make provision-regional
```

Quick start (management cluster):
```bash
# One-time setup: Copy and edit configurations
cp terraform/config/management-cluster/terraform.tfvars.example \
   terraform/config/management-cluster/terraform.tfvars

# Provision complete management cluster environment based on the .tfvars file
make provision-management
```

### Available Make Targets

For all `make` targets, see `make help`.