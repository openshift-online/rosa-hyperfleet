# RHOBS API Gateway Module

Dedicated REST API Gateway with its own ALB and VPC Link for RHOBS (observability) traffic, fully isolated from the Platform API Gateway.

## Features

- **Network Isolation**: Separate ALB, VPC Link, and security groups — no shared path with customer-facing Platform API
- **AWS_IAM Auth**: All requests must be SigV4-signed
- **Per-Path Access Control**: Resource policy enforces two tiers — ingestion endpoints are open to any principal in the same AWS Organization; query endpoints are restricted to the RC account only (E2E tests, internal tooling)
- **EKS Auto Mode**: Target groups tagged with `eks:eks-cluster-name` so the EKS Auto Mode load-balancing controller can discover and register them via `TargetGroupBinding` resources

## Routes

| Method | Path                       | Backend                       | Access          |
| ------ | -------------------------- | ----------------------------- | --------------- |
| POST   | `/api/v1/receive`          | Thanos Receive (:19291)       | Any org account |
| GET    | `/api/v1/query`            | Thanos Query Frontend (:9090) | RC account only |
| GET    | `/api/v1/query_range`      | Thanos Query Frontend (:9090) | RC account only |
| GET    | `/api/v1/rules`            | Thanos Query Frontend (:9090) | RC account only |
| POST   | `/loki/api/v1/push`        | Loki Distributor (:3100)      | Any org account |
| GET    | `/loki/api/v1/query`       | Loki Query Frontend (:3100)   | RC account only |
| GET    | `/loki/api/v1/query_range` | Loki Query Frontend (:3100)   | RC account only |

## Architecture

```
MC (SigV4 Proxy)
    │
    ▼ POST /api/v1/receive (SigV4-signed, any org account)
    │
RHOBS API Gateway (AWS_IAM auth + resource policy)
    │
    ▼ GET /api/v1/query, /api/v1/query_range, /api/v1/rules (RC account only)
    │
VPC Link (dedicated, rhobs-vpc-link SG)
    │
    ▼
Internal ALB (:80) (dedicated, rhobs-alb SG)
    │
    ├──▶ Target Group: thanos-recv (IP)  → Thanos Receive Pods (:19291)
    └──▶ Target Group: thanos-query (IP) → Thanos Query Frontend Pods (:9090)
```

## Connecting Backends

After Terraform creates the infrastructure, deploy a `TargetGroupBinding` in Kubernetes
to register pod IPs with the target group:

```yaml
apiVersion: eks.amazonaws.com/v1
kind: TargetGroupBinding
metadata:
  name: thanos-receive
  namespace: thanos
spec:
  serviceRef:
    name: thanos-receive-router-thanos-receive
    port: 19291
  targetGroupARN: <thanos_receive_target_group_arn from terraform output>
  targetType: ip
```

## Design Decisions

- **No access logging**: This is internal traffic (MC metrics ingestion and RC-account query access), not customer-facing. Access logging is reserved for the Platform API (FedRAMP AU-02). Operational debugging uses CloudWatch metrics from YACE + ALB health checks.
- **No throttling**: Callers are our own MCs — misbehaving senders are fixed at the source, not rate-limited at the gateway.
- **No FedRAMP system use notification**: No human users interact with this API.

## Testing

```bash
# Get the RHOBS API invoke URL
terraform output -raw rhobs_api_url

# Test remote-write endpoint (requires SigV4 signing)
awscurl --service execute-api --region us-east-1 \
  -X POST -H "Content-Type: application/x-protobuf" \
  https://<id>.execute-api.us-east-1.amazonaws.com/prod/api/v1/receive
```
