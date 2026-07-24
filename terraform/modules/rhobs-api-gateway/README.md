# RHOBS API Gateway Module

Dedicated REST API Gateway with its own ALB and VPC Link for RHOBS (observability) traffic, fully isolated from the Platform API Gateway.

## Features

- **Network Isolation**: Separate ALB, VPC Link, and security groups — no shared path with customer-facing Platform API
- **AWS_IAM Auth**: All requests must be SigV4-signed
- **Org-Scoped Access**: Resource policy restricts ingestion to accounts within the same AWS Organization
- **EKS Auto Mode**: Target groups tagged with `eks:eks-cluster-name` so the EKS Auto Mode load-balancing controller can discover and register them via `TargetGroupBinding` resources

## Architecture

```
MC (SigV4 Proxy)
    │
    ▼ POST /api/v1/receive (SigV4-signed)
    │
RHOBS API Gateway (AWS_IAM auth + resource policy)
    │
    ▼
VPC Link (dedicated, rhobs-vpc-link SG)
    │
    ▼
Internal ALB (:80) (dedicated, rhobs-alb SG)
    │
    ▼
Target Group: thanos-recv (IP type)
    │
    ▼ (populated by TargetGroupBinding)
    │
Thanos Receive Pods (:19291)
```

## Connecting Backends

After Terraform creates the infrastructure, deploy a `TargetGroupBinding` in Kubernetes
to register pod IPs with the target group:

```yaml
apiVersion: elbv2.k8s.aws/v1beta1
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

- **Access logging enabled**: Structured JSON access logs are sent to CloudWatch (FedRAMP AU-02) with 365-day retention and KMS encryption. Although this is internal M2M traffic, logging provides an audit trail for cross-account observability ingestion.
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
