# ROSA HyperFleet

## Overview

The ROSA HyperFleet project is a strategic initiative to redesign the architecture of Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes (HCP). This new architecture moves away from a globally-centralized management model to a regionally-distributed approach, where each AWS region operates independently with its own control plane infrastructure.

The goal is to improve reliability, reduce dependencies on global services, and provide customers with lower-latency access to cluster management through regional API endpoints.

## Architecture at a Glance

The architecture consists of three layers within each region:

1. **Regional Cluster (RC)** - EKS-based cluster running core services (Platform API, CLM, Maestro, ArgoCD, Tekton)
2. **Management Clusters (MC)** - EKS clusters hosting customer Hosted Control Planes via HyperShift
3. **Customer Hosted Clusters** - ROSA HCP clusters with control planes in MCs and workers in customer accounts

## Documentation Index

### Design Decisions

Detailed architecture and rationale for key technical decisions:

| Document                                                                           | Topic                                                              |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| [Alerting Architecture](design/alerting-architecture.md)                           | Alerting architecture: fan-out alert routing                       |
| [AWS IAM Hosted Cluster Auth](design/aws-iam-hosted-cluster-authentication.md)     | AWS IAM authentication for hosted clusters                         |
| [DNS Architecture](design/dns-architecture.md)                                     | Hierarchical DNS with zone shards, `deployment_name`, DNSSEC chain |
| [ECS Fargate Bootstrap](design/fully-private-eks-bootstrap.md)                     | How fully private EKS clusters are bootstrapped via ECS            |
| [FIPS-Only EKS Compute](design/fips-eks-compute.md)                                | FIPS NodeClass/NodePool strategy for FedRAMP workload nodes        |
| [GitOps Cluster Configuration](design/gitops-cluster-configuration.md)             | ApplicationSet pattern, progressive deployment, config modes       |
| [Infrastructure Logging](design/infrastructure-logging.md)                         | AWS CloudWatch log groups, KMS encryption, Grafana access          |
| [Logging Platform](design/logging-platform.md)                                     | Application-level log collection (Vector + Loki)                   |
| [Maestro MQTT Resource Distribution](design/maestro-mqtt-resource-distribution.md) | RC-to-MC communication via AWS IoT Core MQTT                       |
| [MC Metrics Remote Write](design/mc-metrics-remote-write.md)                       | MC-to-RC metrics forwarding via RHOBS API Gateway                  |
| [Monitoring Platform](design/monitoring-platform.md)                               | Metrics pipeline (Prometheus + Thanos)                             |
| [Pipeline-Based Lifecycle](design/pipeline-based-lifecycle.md)                     | CodePipeline hierarchy for cluster provisioning                    |
| [Rate Limiting Architecture](design/rate-limiting-architecture.md)                 | Platform API rate limiting                                         |
| [Regional Account Minting](design/regional-account-minting.md)                     | AWS account structure and minting pipelines                        |
| [Regional OIDC Ownership](design/regional-oidc-ownership.md)                       | Regional OIDC ownership for hosted clusters                        |
| [Terraform Resource Adoption](design/terraform-resource-adoption.md)               | Idempotent import of auto-created AWS resources into Terraform     |
| [Spec-to-PR Agent](design/spec-to-pr-agent.md)                                     | Spec-to-PR agent workflow                                          |
| [Testing Strategy](design/testing-strategy.md)                                     | Ephemeral and long-lived test environments                         |
| [Thanos Metrics Infrastructure](design/thanos-metrics-infrastructure.md)           | Thanos S3 storage, operator, and Pod Identity setup                |
| [ZOA Architecture](design/zoa-architecture.md)                                     | Zero Operator Access — system components, flows, infrastructure    |
| [ZOA Trusted Actions](design/zoa-trusted-actions.md)                               | TA template format, API design, CLI, dispatch flow                 |
| [ZOA Security Model](design/zoa-security-model.md)                                 | SA isolation, RBAC, audit trail, threat model, FIPS                |

### How-To Guides

| Document                                                             | Topic                                        |
| -------------------------------------------------------------------- | -------------------------------------------- |
| [Provision a New Environment](environment-provisioning.md)           | Pipeline-based environment provisioning      |
| [Provisioning a Development Environment](development-environment.md) | Ephemeral dev environments                   |
| [Provision a Hosted Cluster](hostedcluster-provisioning.md)          | Create and access a ROSA HCP cluster         |
| [Hosted Cluster Teardown](hostedcluster-teardown.md)                 | Admin-only manual teardown and force cleanup |
| [Adding Alerting Rules](adding-alerting-rules.md)                    | Platform alerting and recording rules        |
| [Adding Component Pre-Merge](adding-component-pre-merge.md)          | Cross-component E2E testing setup            |

### Reference

| Document                                                  | Topic                                     |
| --------------------------------------------------------- | ----------------------------------------- |
| [FAQ](FAQ.md)                                             | Architecture Q&A and pending decisions    |
| [IC Process](process/ic.md)                               | Interrupt Catcher rotation and process    |
| [ArgoCD Configuration](../argocd/README.md)               | ArgoCD setup, config modes, adding charts |
| [CI](../ci/README.md)                                     | E2E testing, ephemeral environments       |
| [Terraform Configurations](../terraform/config/README.md) | Pipeline architecture and cluster configs |

### Standard Operating Procedures

| Document                                          | Topic                                                  |
| ------------------------------------------------- | ------------------------------------------------------ |
| [Rebuild Integration](sop/rebuild-integration.md) | Tear down and re-provision the integration environment |

### Terraform Module Documentation

Each module has its own README with usage, inputs, outputs, and architecture:

- [`eks-cluster`](../terraform/modules/eks-cluster/README.md) - Private EKS cluster with GitOps bootstrap
- [`ecs-bootstrap`](../terraform/modules/ecs-bootstrap/README.md) - ECS Fargate bootstrap infrastructure
- [`api-gateway`](../terraform/modules/api-gateway/README.md) - API Gateway with VPC Link to internal ALB
- [`authz`](../terraform/modules/authz/README.md) - Cedar/AVP authorization (DynamoDB, IAM)
- [`bastion`](../terraform/modules/bastion/README.md) - Ephemeral bastion for private cluster access
- [`maestro-infrastructure`](../terraform/modules/maestro-infrastructure/README.md) - IoT Core, RDS, Secrets Manager for Maestro Server
- [`maestro-agent`](../terraform/modules/maestro-agent/README.md) - IAM and Pod Identity for Maestro Agent
- [`grafana-cloudwatch-logs`](../terraform/modules/grafana-cloudwatch-logs/) - IAM + Pod Identity for Grafana CloudWatch Logs datasources (RC primary + MC reader)
- [`hyperfleet-infrastructure`](../terraform/modules/hyperfleet-infrastructure/README.md) - RDS, Amazon MQ, IAM for HyperFleet (CLM)

### ArgoCD Helm Chart Documentation

- [`hyperfleet-adapter1-chart`](../argocd/config/regional-cluster/hyperfleet-adapter1-chart/README.md) - HyperFleet Adapter (cluster status reporting)
- [`platform-api`](../argocd/config/regional-cluster/platform-api/README.md) - Platform API with Envoy sidecar
- [`thanos`](../argocd/config/regional-cluster/thanos/) - Thanos platform resources (CRs, S3 secret, Pod Identity SA, ALB TargetGroupBinding) plus app-of-apps Application that installs the upstream operator
- [`thanos-operator`](../argocd/config/regional-cluster/thanos-operator/) - Thin wrapper chart that delivers the Thanos operator via OCI-packaged Helm subchart

## Scope

- This architecture is designed exclusively for **ROSA HCP** (Hosted Control Planes)
- ROSA Classic and OSD clusters are not part of this architecture
- All ROSA HCP clusters will eventually migrate to this regional architecture

## Current Status

This is an active development project. Some design decisions are still pending — see [FAQ](FAQ.md) for details on open questions.
