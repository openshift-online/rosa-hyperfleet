# rosa-regional-platform

For the full architecture overview, see [docs/README.md](docs/README.md).

## Repository Structure

```
rosa-regional-platform/
├── argocd/
│   └── config/                       # Live Helm chart configurations
│       ├── applicationset/           # ApplicationSet templates
│       ├── management-cluster/       # Management cluster application templates
│       ├── regional-cluster/         # Regional cluster application templates
│       └── shared/                   # Shared configurations (ArgoCD, etc.)
├── ci/                               # CI automation (e2e tests, janitor)
├── deploy/                           # Per-environment deployment configs
├── docs/                             # Design documents and presentations
├── hack/                             # Developer utility scripts
├── scripts/                          # Dev and pipeline scripts
└── terraform/
    ├── config/                       # Terraform root configurations
    └── modules/                      # Reusable Terraform modules
```

## Quick Start

```bash
make help                     # Show all available targets
make terraform-validate       # Validate Terraform configurations
make helm-lint                # Lint Helm charts
make ephemeral-provision      # Provision ephemeral dev environment
```

## Getting Started

### Pipeline-Based Provisioning (CI/CD)

This is the standard way to provision a region. A central AWS account hosts CodePipelines that automatically provision Regional and Management Clusters when configuration is committed to Git.

See [Provision a New Environment](docs/environment-provisioning.md) for the full walkthrough.

### Ephemeral Dev Environments

For local development and testing, use the ephemeral workflow to provision a short-lived environment in a shared dev account. See [Provisioning a Development Environment](docs/development-environment.md) for a quick-start guide, or run `make help` for all available targets.

## CI

CI is managed through the [OpenShift CI](https://docs.ci.openshift.org/) system (Prow + ci-operator). The job configuration lives in [openshift/release](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-regional-platform).

For the list of jobs, how to trigger them, AWS credentials setup, and local execution, see [ci/README.md](ci/README.md).
