# Regional OIDC Ownership for HyperShift-Hosted Clusters

**Last Updated Date**: 2026-05-19

## Summary

The HyperShift OIDC S3 bucket and CloudFront distribution are owned by the Regional Cluster account — one shared resource per region. Management clusters write OIDC documents to the regional bucket cross-account via S3 bucket policy. Every hosted cluster has a stable OIDC issuer URL that does not change when its control plane moves between management clusters.

## Context

- **Problem Statement**: The OIDC issuer URL for a HyperShift-hosted cluster is embedded in AWS IAM trust policies and in ServiceAccount tokens issued to workloads. It must remain stable for the lifetime of the cluster.

- **Constraints**: The OIDC issuer URL is written into ServiceAccount tokens at cluster creation time and into IAM trust policies by customers. Neither can be updated automatically. The solution must not require HyperShift operator modifications. MC accounts are in a dedicated OU within the organization.

- **Assumptions**: Each region has exactly one Regional Cluster account. All MC accounts for a region belong to a known AWS Organizations OU. MCs are platform-managed accounts governed by SCPs, not customer-operated accounts. CloudFront's global availability is sufficient for the OIDC serving path.

## Architecture

### OIDC Document Flow

```mermaid
graph LR
    subgraph "MC Account (any)"
        HO[HyperShift Operator<br/>Pod Identity Role]
    end

    subgraph "RC Account"
        S3[S3 OIDC Bucket<br/>/{cluster-name}/...]
        CF[CloudFront Distribution<br/>stable domain per region]
    end

    STS[AWS STS<br/>token validation]

    HO -->|cross-account PutObject<br/>via bucket policy| S3
    CF -->|OAC origin request| S3
    STS -->|GET /{cluster-name}/.well-known/openid-configuration| CF
    STS -->|GET /{cluster-name}/keys.json| CF
```

### Cross-Account Write Authorization

The RC S3 bucket policy grants write access to MC HyperShift operator roles using the `aws:PrincipalOrgPaths` condition, restricting access to principals within the MC OU. No STS hop is required — the MC HyperShift operator's Pod Identity role is granted direct cross-account access via the bucket policy. Any account added to the MC OU automatically gains access without a bucket policy update.

```yaml
Condition:
  StringLike:
    aws:PrincipalOrgPaths: "<org-id>/r-xxxx/<mc-ou-id>/*"
    aws:PrincipalArn: "arn:*:iam::*:role/*-hypershift-operator"
```

Actions granted: `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket`.

### Path Structure

OIDC documents are stored under `/{hosted-cluster-name}/`. The path is keyed to the cluster identity, not to the MC hosting it. The issuer URL is stable regardless of which MC currently holds the control plane.

### Data Flow for New Region Provisioning

The RC Terraform module provisions the regional OIDC resources and exports four outputs consumed by the MC provisioning pipeline: `oidc_cloudfront_domain` (the stable issuer URL base), `oidc_bucket_name` (injected into HyperShift configuration), `oidc_bucket_arn` (used as the IAM policy resource target), and `oidc_bucket_region` (used for S3 API endpoint selection). The MC provisioning pipeline reads these values from RC Terraform state — the same pattern used for `rhobs_api_url` — and injects them into MC Terraform variables. The MC then configures HyperShift to write to the regional bucket using its cross-account role.

## Design Rationale

- **No-cache TTL (`default_ttl = 0`, `max_ttl = 0`)**: OIDC discovery documents and JWKS keys change only on key rotation. Setting TTL to zero eliminates the need for cross-account CloudFront cache invalidation after a key rotation: the origin (S3) is always authoritative. OIDC endpoints are low-traffic — AWS STS fetches them only when validating tokens — so no-cache has negligible performance cost.

- **`force_destroy = false`**: The regional OIDC bucket is a permanent regional resource. Accidentally destroying it would break OIDC validation for every hosted cluster in the region simultaneously.

- **`s3:DeleteObject` granted to MC accounts**: Removing this permission would not improve security, because `s3:PutObject` (which allows overwrite) is already granted. Restricting to `PutObject`-only would prevent HyperShift from cleaning up documents for deleted hosted clusters, creating orphaned objects in the bucket.

## Consequences

### Positive

- OIDC issuer URLs are stable across control plane migrations between management clusters. IRSA roles for customer workloads continue to function without any trust policy updates.
- Adding or decommissioning a management cluster does not affect OIDC serving for any other cluster in the region.
- A single CloudFront distribution per region is operationally simpler than one per MC: one domain to monitor, one certificate, one cache behavior to reason about.
- Cross-account write authorization is declarative (bucket policy) and audited via CloudTrail.
- No CloudFront cache invalidation is needed on OIDC key rotation, because TTL is set to zero.

### Negative

- The RC account is in the OIDC document-serving path for all hosted clusters in the region. An RC account outage affects OIDC validation for all clusters in the region. CloudFront's global HA and S3's durability are considered sufficient mitigation.
- Path isolation between MC accounts is enforced by OU membership and CloudTrail audit, not by IAM path prefix conditions. A compromised MC account could in principle overwrite OIDC documents for a hosted cluster assigned to a different MC. This is accepted because MCs are platform-managed accounts under SCP governance, not customer-operated environments.

## Cross-Cutting Concerns

### Reliability

- **Scalability**: One bucket and one CloudFront distribution per region, regardless of the number of MCs or hosted clusters. Path-per-cluster means no naming collisions and no structural changes as the cluster count grows.
- **Observability**: CloudTrail logs all `PutObject`, `DeleteObject`, and `GetObject` calls to the regional OIDC bucket. CloudFront access logs and S3 server access logs provide the serving audit trail. AWS STS token validation errors surface in CloudTrail as `AssumeRoleWithWebIdentity` failures.
- **Resiliency**: S3 provides 11 nines of durability. CloudFront is a globally distributed CDN. With `max_ttl = 0`, every request is a cache miss — a short S3 outage would cause STS token validation failures until S3 recovers.

### Security

- The regional OIDC bucket is fully private. Public reads are served exclusively through CloudFront via Origin Access Control (OAC); no S3 bucket ACLs or public-access exceptions are used.
- Cross-account write access is scoped to the MC OU via `aws:PrincipalOrgPaths`, limiting writers to MC accounts within the platform OU. This does not prevent a compromised MC account from overwriting OIDC documents belonging to clusters on other MCs; CloudTrail audit is the detection control for that scenario.
- OIDC key material (the private signing key) is never written to the OIDC bucket. Only the public JWKS (`keys.json`) and the discovery document are stored there.
- CloudTrail provides a full write audit trail. Any unexpected `PutObject` to another cluster's path is detectable.

### Performance

- `max_ttl = 0` means every STS token validation fetches OIDC documents directly from S3 via CloudFront with no edge caching. OIDC documents are small (a few kilobytes) and fetched infrequently (only during role assumption). The latency impact is negligible for typical workloads.
- CloudFront `PriceClass_100` (US, Canada, Europe) matches the initial target regions and keeps costs minimal.

### Cost

- One CloudFront distribution and one S3 bucket per region. CloudFront costs are proportional to requests and data transfer; zero-TTL caching at OIDC traffic volumes (STS role assumptions only) has negligible cost impact.

### Operability

- The RC Terraform module is the single provisioning point for regional OIDC resources. MC pipelines consume the outputs; they do not manage OIDC infrastructure.
- Rotating OIDC signing keys requires no CloudFront cache invalidation — the new JWKS is live immediately upon `PutObject` completion.
- Debugging OIDC validation failures: check CloudTrail for `AssumeRoleWithWebIdentity` failures, then verify the OIDC discovery document is reachable at `https://<cloudfront-domain>/<cluster-name>/.well-known/openid-configuration`. CloudFront logs identify whether the request reached S3.
