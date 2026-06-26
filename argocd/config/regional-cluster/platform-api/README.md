# platform-api Helm Chart

Helm chart for the ROSA Regional Platform API with Envoy sidecar proxy.

## Overview

This chart deploys:

- Platform API application with authorization middleware
- Envoy sidecar for unified traffic routing
- Service exposing ports 8080 (Envoy), 8000 (API), 8081 (health), 9090 (metrics)
- TargetGroupBinding for AWS Application Load Balancer integration

## Prerequisites

- Kubernetes cluster (EKS recommended)
- AWS Load Balancer Controller installed
- Target Group ARN for the Application Load Balancer

## Configuration

See [values.yaml](values.yaml) for all configuration options. Key settings:

```yaml
platformApi:
  namespace: platform-api

  app:
    name: platform-api
    image:
      repository: quay.io/cdoan0/rosa-hyperfleet-api
      tag: nodb
    args:
      allowedAccounts: "123456789012" # Comma-separated AWS account IDs
      maestroUrl: http://maestro:8000

  envoy:
    enabled: true

  targetGroup:
    arn: "PLACEHOLDER" # AWS Target Group ARN
    targetType: ip
```

## Installation

### Basic Installation

```bash
helm install platform-api ./deployment/helm/rosa-hyperfleet
```

### Production Installation with Custom Values

```bash
helm install platform-api ./deployment/helm/rosa-hyperfleet \
  --set platformApi.targetGroup.arn="arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/platform-api/abc123def456" \
  --set platformApi.app.args.allowedAccounts="111111111111,222222222222,333333333333"
```

### Using a Custom Values File

Create a `custom-values.yaml`:

```yaml
platformApi:
  app:
    image:
      tag: "v1.2.3"
    args:
      allowedAccounts: "111111111111,222222222222"
      maestroUrl: http://maestro.maestro.svc.cluster.local:8000
      logLevel: debug

  targetGroup:
    arn: "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/platform-api/abc123def456"

  deployment:
    replicas: 3

  app:
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        cpu: 1000m
        memory: 1Gi
```

Install with custom values:

```bash
helm install platform-api ./deployment/helm/rosa-hyperfleet \
  -f custom-values.yaml
```

## Upgrading

```bash
helm upgrade platform-api ./deployment/helm/rosa-hyperfleet \
  --set platformApi.targetGroup.arn="arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/platform-api/abc123def456" \
  --set platformApi.app.args.allowedAccounts="111111111111,222222222222"
```

## Uninstallation

```bash
helm uninstall platform-api
```

To also delete the namespace:

```bash
kubectl delete namespace platform-api
```

## Parameters

### Application Configuration

| Parameter                              | Description                          | Default                                     |
| -------------------------------------- | ------------------------------------ | ------------------------------------------- |
| `platformApi.namespace`                | Namespace to deploy into             | `platform-api`                              |
| `platformApi.app.name`                 | Application name                     | `platform-api`                              |
| `platformApi.app.image.repository`     | Container image repository           | `quay.io/cdoan0/rosa-hyperfleet-api` |
| `platformApi.app.image.tag`            | Container image tag                  | `nodb`                                      |
| `platformApi.app.args.allowedAccounts` | Comma-separated AWS account IDs      | `"123456789012"`                            |
| `platformApi.app.args.maestroUrl`      | Maestro service URL                  | `http://maestro:8000`                       |
| `platformApi.app.args.logLevel`        | Log level (debug, info, warn, error) | `info`                                      |
| `platformApi.deployment.replicas`      | Number of replicas                   | `1`                                         |

### Envoy Configuration

| Parameter                            | Description            | Default            |
| ------------------------------------ | ---------------------- | ------------------ |
| `platformApi.envoy.enabled`          | Enable Envoy sidecar   | `true`             |
| `platformApi.envoy.image.repository` | Envoy image repository | `envoyproxy/envoy` |
| `platformApi.envoy.image.tag`        | Envoy image tag        | `v1.31-latest`     |

### Target Group Configuration

| Parameter                            | Description                  | Default         |
| ------------------------------------ | ---------------------------- | --------------- |
| `platformApi.targetGroup.arn`        | AWS Target Group ARN         | `"PLACEHOLDER"` |
| `platformApi.targetGroup.targetType` | Target type (ip or instance) | `ip`            |

## Architecture

```
┌─────────────────────────────────────────┐
│   Application Load Balancer (ALB)      │
└────────────────┬────────────────────────┘
                 │ :8080
                 │
┌────────────────▼────────────────────────┐
│           Envoy Sidecar :8080           │
│  Routes based on path:                  │
│  • /api/* → app:8000                    │
│  • /v0/live → app:8081 (/healthz)       │
│  • /v0/ready → app:8081 (/readyz)       │
│  • /metrics → app:9090                  │
└────────────────┬────────────────────────┘
                 │
     ┌───────────┼───────────┐
     │           │           │
     ▼           ▼           ▼
   :8000       :8081       :9090
    API       Health      Metrics
```

## Health Checks

The application exposes health endpoints on port 8081:

- `/healthz` - Liveness probe
- `/readyz` - Readiness probe

Kubernetes probes check these endpoints directly (not through Envoy).

## API Endpoints

All API endpoints require the `X-Amz-Account-Id` header with an allowed AWS account ID:

```bash
curl -s http://localhost:8080/api/v0/management_clusters \
  -H "X-Amz-Account-Id: 123456789012"
```

## Troubleshooting

### Check pod status

```bash
kubectl get pods -n platform-api
kubectl describe pod -n platform-api <pod-name>
```

### View logs

```bash
# Application logs
kubectl logs -n platform-api <pod-name> -c platform-api

# Envoy logs
kubectl logs -n platform-api <pod-name> -c envoy
```

### Check TargetGroupBinding

```bash
kubectl get targetgroupbinding -n platform-api
kubectl describe targetgroupbinding -n platform-api platform-api
```

### Test health endpoints

```bash
# Port-forward to test locally
kubectl port-forward -n platform-api svc/platform-api 8080:8080

# Test via Envoy
curl http://localhost:8080/v0/live
curl http://localhost:8080/v0/ready
```
