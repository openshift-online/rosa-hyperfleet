# ROSA Hyperfleet (v2): SRE UI Access

**Last Updated Date**: 2026-07-03

## Table of Contents

- [Summary](#summary)
- [Context](#context)
- [Alternatives Considered](#alternatives-considered)
  - [1. Current: SSM + kubectl port-forward](#1-current-ssm--kubectl-port-forward)
  - [2. Kubernetes Ingress Controller](#2-kubernetes-ingress-controller)
  - [3. AWS ALB + OIDC (Recommended)](#3-aws-alb--oidc-recommended)
  - [4. CloudFront + Cognito / Lambda@Edge](#4-cloudfront--cognito--lambdaedge)
- [Design Rationale](#design-rationale)
  - [Phase 1 (initial): Public ALB + OIDC](#phase-1-initial-public-alb--oidc)
  - [Phase 2 (hardening): Public ALB + OIDC + RH Proxy restriction](#phase-2-hardening-public-alb--oidc--rh-proxy-restriction)
  - [Phase 3 (future, if required): Private ALB + VPN](#phase-3-future-if-required-private-alb--vpn)
- [Architecture](#architecture)
  - [ALB Routing Design](#alb-routing-design)
  - [DNS Scheme](#dns-scheme)
  - [Service Mapping](#service-mapping)
  - [Management Cluster Services](#management-cluster-services)
- [Implementation](#implementation)
  - [Terraform Module](#terraform-module)
  - [Helm TargetGroupBindings](#helm-targetgroupbindings)
  - [Module Instantiation Example](#module-instantiation-example)
  - [Configuration Flow](#configuration-flow)
  - [OIDC Configuration](#oidc-configuration)
- [Consequences](#consequences)
- [Cross-Cutting Concerns](#cross-cutting-concerns)
- [Open Questions](#open-questions)
- [Next Steps](#next-steps)

## Summary

This document proposes replacing the current SSM + kubectl port-forward access to SRE UIs (Grafana, ArgoCD, Thanos Querier, Thanos Ruler, Alertmanager, Prometheus, ZOA Console) with an AWS ALB using native OIDC authentication (RH SSO / EmployeeIDP). The approach reuses the existing TargetGroupBinding pattern (proven for Platform API and RHOBS), requires no Kubernetes-level changes, and provides an incremental hardening path (OIDC → proxy IP restriction) without requiring VPN infrastructure.

## Context

- **Problem Statement**: SRE UIs are currently accessible only via SSM + kubectl port-forwarding through ECS Fargate bastions. This approach is flaky (sessions drop, chains break), incompatible with Zero Operator Access (no audit trail, no identity propagation), and not production-ready (relies on temporary bastion infrastructure).
- **Constraints**:
  - No VPN connectivity exists between RH network and Hyperfleet AWS VPCs today
  - EKS clusters are fully private (`endpoint_public_access = false`)
  - Services must stay as `ClusterIP` (no `LoadBalancer` type, no Ingress controller)
  - Same pattern must work across ephemeral, integration, stage, and production environments
  - Solution must be compatible with Zero Operator Access model
- **Assumptions**:
  - RH SSO (EmployeeIDP) supports OIDC with ALB integration
  - TargetGroupBinding CRDs are available in all clusters (EKS Auto Mode)
  - The existing `api-gateway` and `rhobs-api-gateway` Terraform patterns can be reused
  - All SRE services expose HTTP health check endpoints

## Alternatives Considered

### 1. Current: SSM + kubectl port-forward

**How it works**: SRE starts an ECS Fargate bastion via SSM, then chains kubectl port-forward commands to reach individual services.

| Aspect           | Assessment                                                                                                                                                             |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reliability      | Poor — SSM sessions drop, port-forward chains break                                                                                                                    |
| Identity/Audit   | None — SSM session identity only                                                                                                                                       |
| Production-ready | No — bastion infrastructure is temporary                                                                                                                               |
| ZOA compatible   | No — requires VPN + kinit + SSM port-forward scripts; no OIDC identity propagation to services                                                                         |
| UX               | Poor — no bookmarkable URLs; must run `make ephemeral-portforwarding` per cluster, then navigate to `localhost:<port>` per service. Cannot share links with teammates. |

**Verdict**: Unacceptable for production. Adequate only as a temporary workaround during early development.

### 2. Kubernetes Ingress Controller

**How it works**: Deploy an ingress controller (nginx, traefik, or AWS ALB Controller) inside the cluster. Create Ingress resources for each service.

| Aspect                             | Assessment                                                                                                                   |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Maturity                           | Proven in traditional Kubernetes                                                                                             |
| Consistency with existing patterns | Poor — we don't use ingress controllers anywhere; Platform API and RHOBS use Terraform-managed ALBs with TargetGroupBindings |
| OIDC support                       | Requires oauth2-proxy sidecar or external identity-aware proxy                                                               |
| Infrastructure ownership           | Mixed — Kubernetes creates/manages the ALB, Terraform doesn't own it                                                         |
| Lifecycle                          | Tied to ArgoCD sync; infra changes and app changes coupled                                                                   |
| Sidecar requirement                | Needs oauth2-proxy sidecar in each service's Helm chart for OIDC — intrusive changes to upstream charts                      |

**Verdict**: Not recommended. Introduces a new pattern inconsistent with existing infrastructure. Blurs Terraform/Kubernetes ownership boundaries.

### 3. AWS ALB + OIDC (Recommended)

**How it works**: Terraform creates a dedicated ALB with wildcard TLS certificate, host-based listener rules, and `authenticate-oidc` actions. Each rule authenticates via RH SSO before forwarding to a target group. Helm charts add `TargetGroupBinding` CRDs to wire pod IPs into target groups.

| Aspect                   | Assessment                                                                               |
| ------------------------ | ---------------------------------------------------------------------------------------- |
| Consistency              | Follows existing `api-gateway` and `rhobs-api-gateway` patterns exactly                  |
| OIDC support             | Native ALB `authenticate-oidc` action — no proxy deployments needed                      |
| Infrastructure ownership | Clear — Terraform owns ALB/TG/DNS, Helm owns TargetGroupBindings                         |
| Kubernetes changes       | None — services stay ClusterIP                                                           |
| Incremental hardening    | SG can be tightened to proxy IPs (Phase 2) without ALB changes; VPN-ready if ever needed |

**Verdict**: Recommended. Reuses proven patterns, native OIDC, clean separation of concerns.

### 4. CloudFront + Cognito / Lambda@Edge

**How it works**: CloudFront distribution with either AWS Cognito (federated to RH SSO) or Lambda@Edge for OIDC authentication, origin pointing to internal ALB.

| Aspect              | Assessment                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| Global distribution | Unnecessary — SRE UIs are regional, not customer-facing                                          |
| Cost                | Higher — CloudFront + Cognito user pool (or Lambda invocations per request)                      |
| Complexity          | Cognito federation to RH SSO adds another identity layer to manage. Lambda@Edge has cold starts. |
| Consistency         | Not aligned with existing patterns (no other service uses CloudFront/Cognito)                    |

**Note**: Cognito can also be used directly with ALB (without CloudFront) — ALB supports Cognito as an authentication action. However, Cognito adds an intermediate identity provider between the ALB and RH SSO, whereas ALB `authenticate-oidc` talks directly to RH SSO without a middleman. Cognito is more useful when you need user pools, MFA, or multiple identity providers — none of which apply here.

**Verdict**: Not recommended. Both CloudFront+Cognito and CloudFront+Lambda@Edge add services and complexity for a problem that ALB-native `authenticate-oidc` already solves directly. The ALB approach is simpler, cheaper, and consistent with our existing patterns.

## Design Rationale

### Phase 1 (initial): Public ALB + OIDC

Deploy a public (internet-facing) ALB with `authenticate-oidc` actions on all listener rules. Security group allows `0.0.0.0/0` on port 443. Protection is identity-only (RH SSO restricts to authenticated Red Hat employees with password + MFA).

**Why start here**: No infrastructure dependencies. Immediately solves flakiness, provides identity/audit, and works across all environments without VPN.

**If Phase 2 cannot be achieved** (proxy IPs unavailable or unstable), consider adding AWS WAF with rate-limiting rules on the ALB as extra protection against automated attacks on the OIDC endpoint.

### Phase 2 (hardening): Public ALB + OIDC + RH Proxy restriction

ALB remains internet-facing, but the security group is restricted to the public egress IPs of Red Hat's corporate proxy. Engineers configure their browser with a PAC file that routes SRE UI hostnames through the proxy.

**Why this is attractive**:

- No RH IT dependency for network infrastructure — uses existing corporate proxy
- No VPN to build — ALB stays public, just SG change + PAC file distribution
- Defense in depth — network restriction (proxy IPs) + identity (OIDC)
- Same pattern already used at RH for accessing restricted internal services via browser proxy
- Small number of IPs to whitelist (one per RH datacenter)

**PAC file example**:

```javascript
function FindProxyForURL(url, host) {
  if (shExpMatch(host, "*.sre.*.rosa.devshift.net")) {
    return "PROXY <rh-corporate-proxy>";
  }
  if (shExpMatch(host, "*.sre.*.rosa.redhat.com")) {
    return "PROXY <rh-corporate-proxy>";
  }
  return "DIRECT";
}
```

**Open item**: We need the proxy egress IPs to be provided by RH IT in an automated way (single source of truth) that can be embedded into our Terraform configuration. If a fully automated sync isn't available, we need at minimum a known place to check so we can update easily when IPs change.

### Phase 3 (future, if required): Private ALB + VPN

If full VPN connectivity between RH network and Hyperfleet VPCs becomes necessary, int/stage/prod environments could migrate to a private (internal) ALB. The transition would be a variable change: `internal = true`, `subnet_ids = private subnets`.

However, we'd prefer to avoid this path if possible:

- Requires RH IT coordination for Site-to-Site VPN or Transit Gateway peering
- Adds complex manual configuration to our automated pipelines
- Network interconnection with RH IT networks is operationally heavy

Given that this is just browser access to SRE UIs already protected by RH SSO (OIDC), and Phase 2 already restricts to specific proxy IPs, full VPN connectivity may not be justified for this use case. We will evaluate if Phase 3 is needed based on security requirements, but Phase 2 should provide sufficient defense in depth.

This is the same networking problem as rosa-boundary (break-glass access to private EKS). If VPN infrastructure is ever built for that purpose, SRE UI access would ride on the same connectivity.

## Architecture

### ALB Routing Design

One ALB per regional cluster with host-based listener rules. Each rule has two actions: `authenticate-oidc` (redirect to RH SSO if unauthenticated) then `forward` (to the service's target group).

```
ALB (HTTPS:443, wildcard cert: *.sre.<regional_domain>)
├── grafana.sre.*       → authenticate-oidc → grafana TG (:3000)
├── argocd.sre.*        → authenticate-oidc → argocd TG (:8080)
├── thanos-querier.sre.* → authenticate-oidc → thanos-query TG (:9090)
├── thanos-ruler.sre.*  → authenticate-oidc → thanos-ruler TG (:9090)
├── alertmanager.sre.*  → authenticate-oidc → alertmanager TG (:9093)
├── zoa.sre.*           → authenticate-oidc → zoa-console TG (:8080)
├── prometheus.sre.*    → authenticate-oidc → prometheus TG (:9090)
└── Default             → fixed-response 404
```

### DNS Scheme

Uses the existing regional zone hierarchy:

```
<service>.sre.<region>.<env>.<domain>
```

Examples:

| Environment | Service        | FQDN                                                  |
| ----------- | -------------- | ----------------------------------------------------- |
| Integration | Grafana        | `grafana.sre.us-east-1.int0.rosa.devshift.net`        |
| Integration | ArgoCD         | `argocd.sre.us-east-1.int0.rosa.devshift.net`         |
| Integration | Thanos Querier | `thanos-querier.sre.us-east-1.int0.rosa.devshift.net` |
| Integration | Alertmanager   | `alertmanager.sre.us-east-1.int0.rosa.devshift.net`   |
| Integration | Thanos Ruler   | `thanos-ruler.sre.us-east-1.int0.rosa.devshift.net`   |
| Integration | ZOA Console    | `zoa.sre.us-east-1.int0.rosa.devshift.net`            |
| Integration | Prometheus     | `prometheus.sre.us-east-1.int0.rosa.devshift.net`     |
| Ephemeral   | Grafana        | `grafana.sre.us-east-1.eph-7e3884.rosa.devshift.net`  |
| MC (int)    | ArgoCD         | `argocd.sre.mc01.us-east-1.int0.rosa.devshift.net`    |
| Production  | Grafana        | `grafana.sre.us-east-1.prod.rosa.redhat.com`          |

**TLS**: Wildcard ACM certificate `*.sre.<region>.<env>.<domain>`, DNS-validated via Route53. One certificate covers all SRE services.

**Note**: In Terraform, the composed `<region>.<env>.<domain>` string is passed as `var.regional_domain` (e.g., `us-east-1.int0.rosa.devshift.net` for RC, `mc01.us-east-1.int0.rosa.devshift.net` for MC).

### Service Mapping

| Service        | K8s Service                          | Namespace      | Port | Health Check  | Description                                           | OIDC                                          |
| -------------- | ------------------------------------ | -------------- | ---- | ------------- | ----------------------------------------------------- | --------------------------------------------- |
| Grafana        | `grafana`                            | `grafana`      | 3000 | `/api/health` | Dashboards for metrics, logs (K8s and AWS infra)      | Native OIDC support; ALB OIDC also works      |
| ArgoCD         | `argocd-server`                      | `argocd`       | 8080 | `/healthz`    | GitOps deployment UI (app status, diff, logs)         | Native OIDC support; use HTTP port behind ALB |
| Thanos Querier | `thanos-query-frontend-thanos-query` | `thanos`       | 9090 | `/-/ready`    | Consolidated PromQL queries across all RC/MCs         | No native auth — ALB OIDC required            |
| Thanos Ruler   | `thanos-ruler-thanos-ruler`          | `thanos`       | 9090 | `/-/ready`    | Alerting rule evaluation and recording rules          | No native auth — ALB OIDC required            |
| Alertmanager   | `monitoring-alertmanager`            | `monitoring`   | 9093 | `/-/ready`    | Alert routing, silencing, and inhibition              | No native auth — ALB OIDC required            |
| ZOA Console    | `zoa-console`                        | `platform-api` | 8080 | `/healthz`    | Trusted action audit and executions                   | No native auth — ALB OIDC required            |
| Prometheus     | `prometheus-server`                  | `monitoring`   | 9090 | `/-/ready`    | Local scrape data (remote-writes to Thanos); fallback | No native auth — ALB OIDC required            |

### Management Cluster Services

Same architecture deployed **per MC account**, exposing ArgoCD and Prometheus:

- Same Terraform module instantiated in each MC account
- DNS: `<service>.sre.<mc-name>.<region>.<env>.<domain>`
- Wildcard cert: `*.sre.<mc-name>.<region>.<env>.<domain>`
- ALB lives in the MC VPC (no cross-VPC connectivity needed)
- Can be extended to more MC services later by adding entries to the services map

## Implementation

> **Note**: The following is a proposed implementation to be evaluated during development.
> It represents the likely technical direction based on existing patterns in the codebase
> (e.g., `rhobs-api-gateway`), but details — particularly around RH SSO/OIDC integration,
> group-based authorization, and phased rollout — remain open questions that should be
> validated during implementation.

### Terraform Module

New module `terraform/modules/sre-ui-alb/` (follows `rhobs-api-gateway` ALB + SG patterns):

| Resource               | Purpose                                                              |
| ---------------------- | -------------------------------------------------------------------- |
| `aws_lb`               | Application Load Balancer (internal or internet-facing via variable) |
| `aws_acm_certificate`  | Wildcard cert `*.sre.<regional_domain>`, DNS-validated               |
| `aws_lb_listener`      | HTTPS:443 with default 404 fixed-response                            |
| `aws_lb_target_group`  | One per service (`for_each` over services map). IP target type.      |
| `aws_lb_listener_rule` | Host-based matching + `authenticate-oidc` action + forward           |
| `aws_route53_record`   | Alias records for each service hostname                              |
| `aws_security_group`   | HTTPS from allowed CIDRs + specific port egress to node SG           |
| `aws_kms_key`          | KMS key for ALB access log encryption (FedRAMP AU-09)                |
| `aws_s3_bucket`        | ALB access logs bucket (365 days retention, KMS-encrypted)           |

#### Variables (`variables.tf`)

```hcl
# =============================================================================
# Required Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ALB will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for ALB placement (public for Phase 1/2, private for Phase 3)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least 2 subnets are required for ALB high availability."
  }
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID - ALB needs to send traffic to pods via this SG"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name - required for tagging target group with eks:eks-cluster-name for Auto Mode IAM permissions"
  type        = string
}

variable "regional_domain" {
  description = "Regional domain name (e.g., us-east-1.int0.rosa.devshift.net)"
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS records"
  type        = string
}

variable "oidc_client_id" {
  description = "OIDC client ID for RH SSO / EmployeeIDP"
  type        = string
}

variable "oidc_client_secret" {
  description = "OIDC client secret"
  type        = string
  sensitive   = true
}

# =============================================================================
# Optional Variables
# =============================================================================

variable "internal" {
  description = "Whether the ALB is internal (Phase 3) or internet-facing (Phase 1/2)"
  type        = bool
  default     = false
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the ALB (Phase 1: 0.0.0.0/0, Phase 2: proxy IPs)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "oidc_issuer" {
  description = "OIDC issuer URL"
  type        = string
  default     = "https://auth.redhat.com/auth/realms/EmployeeIDP"
}

variable "services" {
  description = "Services to expose via the ALB. Keys must be short (TG name limit: 32 chars)."
  type = map(object({
    port        = number
    health_path = string
    dns_prefix  = string
  }))
  # No default — caller must explicitly declare which services to expose.
  # This ensures RC and MC configs are self-documenting and reviewable.
}
```

#### ALB and Listener Rules (`alb.tf`)

```hcl
# =============================================================================
# SRE UI Application Load Balancer
#
# Dedicated ALB for SRE browser access to internal tools. Uses host-based
# routing with OIDC authentication (RH SSO) on every rule.
#
# Flow: Browser -> ALB (OIDC auth) -> Target Group -> Pod IPs (via TGB)
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "sre" {
  name               = "${var.regional_id}-sre-ui"
  internal           = var.internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "sre-ui"
    enabled = true
  }

  tags = {
    Name = "${var.regional_id}-sre-ui"
  }
}

# -----------------------------------------------------------------------------
# ACM Certificate (wildcard for all SRE services)
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "sre_wildcard" {
  domain_name       = "*.sre.${var.regional_domain}"
  validation_method = "DNS"

  # ACM certificates are free when used with AWS services (ALB, CloudFront, API GW).
  # No per-cert cost, no renewal cost — fully managed auto-renewal.

  tags = {
    Name = "${var.regional_id}-sre-ui-wildcard"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.sre_wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "sre_wildcard" {
  certificate_arn         = aws_acm_certificate.sre_wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# -----------------------------------------------------------------------------
# HTTPS Listener (default 404)
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.sre.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.sre_wildcard.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# -----------------------------------------------------------------------------
# Target Groups (one per service)
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "services" {
  for_each = var.services

  name        = "${var.regional_id}-sre-${each.key}"
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = each.value.health_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-sre-${each.key}"
    "eks:eks-cluster-name" = var.cluster_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Listener Rules (OIDC + forward, one per service)
# -----------------------------------------------------------------------------

resource "aws_lb_listener_rule" "services" {
  for_each = var.services

  listener_arn = aws_lb_listener.https.arn

  action {
    type = "authenticate-oidc"
    authenticate_oidc {
      authorization_endpoint     = "${var.oidc_issuer}/protocol/openid-connect/auth"
      client_id                  = var.oidc_client_id
      client_secret              = var.oidc_client_secret
      issuer                     = var.oidc_issuer
      token_endpoint             = "${var.oidc_issuer}/protocol/openid-connect/token"
      user_info_endpoint         = "${var.oidc_issuer}/protocol/openid-connect/userinfo"
      scope                      = "openid email profile"
      session_timeout            = 28800
      on_unauthenticated_request = "authenticate"
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.services[each.key].arn
  }

  condition {
    host_header {
      values = ["${each.value.dns_prefix}.${var.regional_domain}"]
    }
  }
}

# -----------------------------------------------------------------------------
# DNS Records (alias to ALB)
# -----------------------------------------------------------------------------

resource "aws_route53_record" "services" {
  for_each = var.services

  zone_id = var.route53_zone_id
  name    = "${each.value.dns_prefix}.${var.regional_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.sre.dns_name
    zone_id                = aws_lb.sre.zone_id
    evaluate_target_health = true
  }
}
```

#### Security Groups (`security-groups.tf`)

```hcl
# =============================================================================
# Security Groups
#
# ALB SG controls:
# - Ingress: HTTPS (443) from allowed CIDRs
# - Egress: specific service ports to node SG only (least privilege)
# =============================================================================

# -----------------------------------------------------------------------------
# ALB Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.regional_id}-sre-ui-alb"
  description = "SRE UI ALB - HTTPS ingress from allowed CIDRs"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = false

  tags = {
    Name = "${var.regional_id}-sre-ui-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
  description       = "HTTPS from ${each.value}"
}

# Per-service egress rules to node SG (least privilege, no 0.0.0.0/0)
# Deduplicated by port to avoid redundant rules for services sharing a port.
locals {
  service_ports = toset([for s in var.services : s.port])
}

resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  for_each = local.service_ports

  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to pods on port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = var.node_security_group_id
}

# OIDC callback requires outbound HTTPS to RH SSO
resource "aws_vpc_security_group_egress_rule" "alb_to_oidc" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS egress for OIDC token/userinfo callbacks to RH SSO"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# Node Security Group Ingress Rules
#
# Allow SRE ALB to send health checks and traffic to service pods.
# Targets cluster_primary_security_group_id (EKS Auto Mode).
# -----------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  for_each = local.service_ports

  security_group_id            = var.node_security_group_id
  description                  = "Allow SRE ALB traffic to pods on port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id
}
```

#### Access Logs (`logs.tf`)

```hcl
# =============================================================================
# ALB Access Logs (FedRAMP AU-02, AU-09)
#
# S3 bucket with KMS encryption, intelligent tiering, and 365-day retention.
# =============================================================================

resource "aws_kms_key" "alb_logs" {
  description             = "KMS key for SRE UI ALB access log encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowS3Service"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.regional_id}-sre-ui-alb-logs"
  }
}

resource "aws_kms_alias" "alb_logs" {
  name          = "alias/${var.regional_id}-sre-ui-alb-logs"
  target_key_id = aws_kms_key.alb_logs.key_id
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.regional_id}-sre-ui-alb-logs"

  tags = {
    Name = "${var.regional_id}-sre-ui-alb-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.alb_logs.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "tiered-retention"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowALBLogDelivery"
        Effect = "Allow"
        Principal = {
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/sre-ui/*"
      }
    ]
  })
}
```

#### Outputs (`outputs.tf`)

```hcl
output "target_group_arns" {
  description = "Map of service name to target group ARN (consumed by Helm TargetGroupBindings)"
  value       = { for k, tg in aws_lb_target_group.services : k => tg.arn }
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.sre.dns_name
}

output "alb_security_group_id" {
  description = "ALB security group ID (for Phase 2 CIDR updates)"
  value       = aws_security_group.alb.id
}

output "service_urls" {
  description = "Map of service name to FQDN"
  value       = { for k, r in aws_route53_record.services : k => "https://${r.fqdn}" }
}
```

### Helm TargetGroupBindings

Each service chart gets a `TargetGroupBinding` template. SRE UI access is always deployed in all environments (including ephemeral) — there is no opt-out:

```yaml
apiVersion: eks.amazonaws.com/v1
kind: TargetGroupBinding
metadata:
  name: {{ include "chart.fullname" . }}-sre-ui
spec:
  serviceRef:
    name: {{ .Values.sre_ui.service_name | default (include "chart.fullname" .) }}
    port: {{ .Values.sre_ui.service_port | default 80 }}
  targetGroupARN: {{ .Values.sre_ui.target_group_arn | quote }}
  targetType: ip
```

The target group ARN is always provided via Terraform outputs — the ALB module is part of the base infrastructure for every cluster.

### Module Instantiation Example

**Regional Cluster** (all SRE UIs):

```hcl
module "sre_ui_alb" {
  source = "../../modules/sre-ui-alb"

  regional_id            = var.regional_id
  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.public_subnet_ids
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name
  regional_domain        = local.regional_domain
  route53_zone_id        = aws_route53_zone.regional[0].zone_id
  oidc_client_id         = data.aws_ssm_parameter.sre_oidc_client_id.value
  oidc_client_secret     = data.aws_ssm_parameter.sre_oidc_client_secret.value

  # Phase 1: open to internet (OIDC protects)
  allowed_cidrs = ["0.0.0.0/0"]

  # Phase 2: restrict to RH proxy egress IPs
  # allowed_cidrs = var.rh_proxy_egress_cidrs

  services = {
    grafana  = { port = 3000, health_path = "/api/health", dns_prefix = "grafana.sre" }
    argocd   = { port = 8080, health_path = "/healthz", dns_prefix = "argocd.sre" }
    th-query = { port = 9090, health_path = "/-/ready", dns_prefix = "thanos-querier.sre" }
    th-ruler = { port = 9090, health_path = "/-/ready", dns_prefix = "thanos-ruler.sre" }
    alertmgr = { port = 9093, health_path = "/-/ready", dns_prefix = "alertmanager.sre" }
    zoa      = { port = 8080, health_path = "/healthz", dns_prefix = "zoa.sre" }
    prom     = { port = 9090, health_path = "/-/ready", dns_prefix = "prometheus.sre" }
  }
}
```

**Management Cluster** (ArgoCD only):

```hcl
module "sre_ui_alb" {
  source = "../../modules/sre-ui-alb"

  regional_id            = var.regional_id
  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.public_subnet_ids
  node_security_group_id = module.management_cluster.node_security_group_id
  cluster_name           = module.management_cluster.cluster_name
  regional_domain        = local.mc_domain
  route53_zone_id        = aws_route53_zone.mc[0].zone_id
  oidc_client_id         = data.aws_ssm_parameter.sre_oidc_client_id.value
  oidc_client_secret     = data.aws_ssm_parameter.sre_oidc_client_secret.value
  allowed_cidrs          = ["0.0.0.0/0"]

  services = {
    argocd = { port = 8080, health_path = "/healthz", dns_prefix = "argocd.sre" }
    prom   = { port = 9090, health_path = "/-/ready", dns_prefix = "prometheus.sre" }
  }
}
```

### Configuration Flow

```
Terraform outputs → SSM/Secret → ArgoCD ApplicationSet → Helm values → TargetGroupBinding
```

Same flow as Platform API and RHOBS target groups today.

### OIDC Configuration

| Parameter              | Value                                             |
| ---------------------- | ------------------------------------------------- |
| Issuer                 | `https://auth.redhat.com/auth/realms/EmployeeIDP` |
| Authorization Endpoint | `<issuer>/protocol/openid-connect/auth`           |
| Token Endpoint         | `<issuer>/protocol/openid-connect/token`          |
| UserInfo Endpoint      | `<issuer>/protocol/openid-connect/userinfo`       |
| Scope                  | `openid email profile`                            |
| Session Timeout        | 28800s (8 hours)                                  |
| Cookie Name            | `AWSELBAuthSessionCookie`                         |
| On Unauthenticated     | `authenticate` (redirect to login)                |

**Redirect URI pattern**: `https://<host>/oauth2/idpresponse`

**Identity headers forwarded to services** (after authentication):

| Header                    | Content                              |
| ------------------------- | ------------------------------------ |
| `x-amzn-oidc-accesstoken` | Access token from RH SSO             |
| `x-amzn-oidc-identity`    | User's email (from `sub` claim)      |
| `x-amzn-oidc-data`        | JWT with full claims (signed by ALB) |

## Consequences

### Positive

- Stable, reliable access — AWS-managed ALB instead of SSM chains
- Identity and audit — OIDC identity + ALB access logs for every request
- ZOA compatible — browser-based with identity propagation
- Production-ready — same pattern used for customer-facing Platform API
- No Kubernetes changes — services stay as ClusterIP
- Incremental hardening — can tighten SG to proxy IPs (Phase 2) without architectural changes
- Scalable — adding a new service is one Terraform entry + one Helm template

### Negative

- OIDC client management — need to register/maintain client with RH SSO
- PAC file distribution (Phase 2) — manual browser configuration for engineers
- Proxy IP tracking (Phase 2) — need to keep SG in sync if proxy IPs change
- Phase 3 dependency — full VPN would require RH IT coordination (complex, prefer to avoid unless required)

### Risks

- **EmployeeIDP redirect URI support**: If wildcard redirect URIs are not supported, ephemeral environments may need a workaround (single client with enumerated URIs, or per-env client registration)
- **Proxy IP stability**: If IPs change frequently without notification, Phase 2 could break access

## Cross-Cutting Concerns

- **Monitoring**: ALB metrics (4xx/5xx, target health) integrated into existing CloudWatch/Grafana dashboards. The ALB namespace will need to be added to the CloudWatch Exporter scrape configuration (YACE) to surface metrics in Prometheus/Grafana.
- **Cost**: One ALB per regional cluster (~$20/month + LCU charges). Minimal compared to existing infrastructure.
- **Observability**: ALB access logs to S3 provide full request audit trail (who accessed what, when)
- **Disaster recovery**: ALB is regional AWS-managed. If the region is down, SRE UIs are irrelevant anyway.
- **ArgoCD RBAC**: ArgoCD's native OIDC is read-only by default. Write access (sync, rollback) can be enabled per-environment via Helm values templating — e.g., read-write in ephemeral, read-only in production.
- **Grafana roles**: Grafana defaults to read-only (Viewer). Write access (Editor/Admin) can be overridden per-environment via Helm values templating, same pattern as ArgoCD.

## Open Questions

1. **OIDC client registration**: Who owns the RH SSO client? Does EmployeeIDP support wildcard redirect URIs for ephemeral environments, or do we need a single static client?
2. **Proxy IP source of truth**: What's the canonical, automatable source for proxy egress IPs? How do we keep our SG in sync?

## Next Steps

- [ ] Validate OIDC client registration with RH SSO / EmployeeIDP team
- [ ] Confirm proxy IP source of truth and update mechanism with RH IT
- [ ] Implement `terraform/modules/sre-ui-alb/` module
- [ ] Add TargetGroupBinding templates to service Helm charts
- [ ] Deploy Phase 1 in ephemeral environment and validate
- [ ] Distribute PAC file and deploy Phase 2 (proxy restriction) for integration
- [ ] Evaluate Phase 3 (VPN) only if security requirements demand it beyond Phase 2
