# ROSA Regional Platform

## Overview

The ROSA Regional Platform project is a strategic initiative to redesign the architecture of Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes (HCP). This new architecture moves away from a globally-centralized management model to a regionally-distributed approach, where each AWS region operates independently with its own control plane infrastructure.

The goal is to improve reliability, reduce dependencies on global services, and provide customers with lower-latency access to cluster management through regional API endpoints.

## Architecture at a Glance

The architecture consists of three layers within each region:

1. **Regional Cluster (RC)** - EKS-based cluster running core services (Platform API, CLM, Maestro, ArgoCD, Tekton, Prometheus)
2. **Management Clusters (MC)** - EKS clusters hosting customer Hosted Control Planes via HyperShift
3. **Customer Hosted Clusters** - ROSA HCP clusters with control planes in MCs and workers in customer accounts

## Documentation Index

### Design Decisions

Detailed architecture and rationale for key technical decisions:

| Document                                                                           | Topic                                                        |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| [ECS Fargate Bootstrap](design/fully-private-eks-bootstrap.md)                     | How fully private EKS clusters are bootstrapped via ECS      |
| [GitOps Cluster Configuration](design/gitops-cluster-configuration.md)             | ApplicationSet pattern, progressive deployment, config modes |
| [Maestro MQTT Resource Distribution](design/maestro-mqtt-resource-distribution.md) | RC-to-MC communication via AWS IoT Core MQTT                 |
| [Pipeline-Based Lifecycle](design/pipeline-based-lifecycle.md)                     | CodePipeline hierarchy for cluster provisioning              |
| [Regional Account Minting](design/regional-account-minting.md)                     | AWS account structure and minting pipelines                  |
| [Testing Strategy](design/testing-strategy.md)                                     | Ephemeral and long-lived test environments                   |

### How-To Guides

| Document                                                             | Topic                                   |
| -------------------------------------------------------------------- | --------------------------------------- |
| [Provision a New Environment](environment-provisioning.md)           | Pipeline-based environment provisioning |
| [Provisioning a Development Environment](development-environment.md) | Ephemeral dev environments              |

### Reference

| Document                                                  | Topic                                     |
| --------------------------------------------------------- | ----------------------------------------- |
| [FAQ](FAQ.md)                                             | Architecture Q&A and pending decisions    |
| [ArgoCD Configuration](../argocd/README.md)               | ArgoCD setup, config modes, adding charts |
| [CI](../ci/README.md)                                     | E2E testing, ephemeral environments       |
| [Terraform Configurations](../terraform/config/README.md) | Pipeline architecture and cluster configs |

### Terraform Module Documentation

Each module has its own README with usage, inputs, outputs, and architecture:

- [`eks-cluster`](../terraform/modules/eks-cluster/README.md) - Private EKS cluster with GitOps bootstrap
- [`ecs-bootstrap`](../terraform/modules/ecs-bootstrap/README.md) - ECS Fargate bootstrap infrastructure
- [`api-gateway`](../terraform/modules/api-gateway/README.md) - API Gateway with VPC Link to internal ALB
- [`authz`](../terraform/modules/authz/README.md) - Cedar/AVP authorization (DynamoDB, IAM)
- [`bastion`](../terraform/modules/bastion/README.md) - Ephemeral bastion for private cluster access
- [`maestro-infrastructure`](../terraform/modules/maestro-infrastructure/README.md) - IoT Core, RDS, Secrets Manager for Maestro Server
- [`maestro-agent`](../terraform/modules/maestro-agent/README.md) - IAM and Pod Identity for Maestro Agent
- [`hyperfleet-infrastructure`](../terraform/modules/hyperfleet-infrastructure/README.md) - RDS, Amazon MQ, IAM for HyperFleet (CLM)

### ArgoCD Helm Chart Documentation

- [`hyperfleet-system`](../argocd/config/regional-cluster/hyperfleet-system/README.md) - HyperFleet components (API, Sentinel, Adapter)
- [`platform-api`](../argocd/config/regional-cluster/platform-api/README.md) - Platform API with Envoy sidecar

### Presentations

Slidev-based presentations for project overview and milestones:

- [Project Overview](presentations/project/README.md) - ROSA Regional Platform project presentation
- [Milestone 1](presentations/milestone-1/README.md) - Full region provisioning demonstration

## Scope

- This architecture is designed exclusively for **ROSA HCP** (Hosted Control Planes)
- ROSA Classic and OSD clusters are not part of this architecture
- All ROSA HCP clusters will eventually migrate to this regional architecture

## Current Status

This is an active development project. Some design decisions are still pending — see [FAQ](FAQ.md) for details on open questions.
