# Security Audit — rosa-regional-platform

**Audit Date:** 2026-06-15
**Auditor:** security-audit-agent (automated)
**Scope:** Full static analysis of Terraform modules, ArgoCD/Helm charts, CI/CD scripts, Dockerfiles
**Previous PRs:** #458, #511, #566 (superseded by this report)

> This PR supersedes PR #566 (and earlier #511, #458). No previous user comments dismissed any findings as non-issues, so all carry-over findings remain active.

---

## CRITICAL Findings

### CRIT-1 — API Gateway Resource Policy Allows Any AWS Principal **(carry-over from #566, unresolved)**

**File:** `terraform/modules/api-gateway/resource-policy.tf` lines 10–25

```hcl
policy = jsonencode({
  Statement = [
    {
      Sid    = "AllowAllAWSAccounts"
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action   = "execute-api:Invoke"
      Resource = "arn:aws:execute-api:..."
    }
  ]
})
```

**Risk:** `Principal: { AWS: "*" }` permits **any authenticated AWS principal in any account** to invoke the management and regional cluster APIs using valid SigV4 credentials. This comment in the file — *"The Platform API backend handles its own authorization, so the gateway does not restrict by caller account"* — confirms this is intentional but is a significant defense-in-depth gap.

**Attack vector:** An attacker with any AWS account obtains credentials (free tier), discovers the API Gateway invoke URL through DNS enumeration, and makes authenticated API calls. The only gating is at the application layer. If the application authorization layer has any bug (see rosa-regional-platform-api findings), there is no AWS-level perimeter to stop exploitation.

**What to mitigate:** Replace `AWS = "*"` with `aws:PrincipalOrgID` or `aws:PrincipalOrgPaths` with a `StringEquals` condition scoped to the Red Hat AWS Organization. Alternatively, enumerate allowed AWS account ARNs explicitly.

---

### CRIT-2 — Wildcard API Gateway ARN in IAM Policies for Prometheus and Loki Forwarders **(carry-over from #566, unresolved)**

**Files:**
- `terraform/modules/prometheus-remote-write/iam.tf`
- `terraform/modules/loki-log-forwarder/iam.tf`

Both forwarder IAM roles allow:
```
arn:aws:execute-api:<region>:<rc-account>:*/POST/api/v1/receive
arn:aws:execute-api:<region>:<rc-account>:*/POST/loki/api/v1/push
```

**Risk:** The `*` wildcard in the API Gateway ID position means the MC roles can invoke **any** API Gateway in the regional account with matching path — including a rogue one created by an attacker.

**Attack vector:** Attacker with write access to the regional account creates a new API Gateway with paths `/POST/api/v1/receive`. The MC-side Prometheus forwarder sends all metrics (potentially including sensitive cluster telemetry) to the attacker's endpoint.

**What to mitigate:** Pass the RC API Gateway ID as a Terraform output (stored in SSM Parameter Store or Terraform remote state) and consume it in the MC stack IAM policies. Until then, add an `aws:ResourceTag` condition limiting the target API Gateway to tagged resources.

---

### CRIT-3 — Grafana Anonymous Authentication with Admin Role **(carry-over from #566, unresolved)**

**File:** `argocd/config/regional-cluster/grafana/values.yaml` lines ~52–57

```yaml
"auth.anonymous":
  enabled: true
  org_role: Admin
auth:
  disable_login_form: true
```

**Risk:** Any client that can reach the Grafana service — including any pod within the cluster or any user who escapes network controls — gets **full admin access without credentials**. An admin can delete/modify dashboards, reconfigure datasources to point at attacker-controlled endpoints, exfiltrate all metrics and logs, and create API keys for persistent access.

**Attack vector:** A compromised pod in the cluster issues `curl http://grafana/api/dashboards` and receives full admin access. If Grafana is ever exposed via an Ingress (even transiently), any internet user gets admin.

**What to mitigate:** Either (a) configure SSO/OIDC authentication with the cluster's identity provider, or (b) drop `org_role` to `Viewer` if anonymous read-only access is the intent. The `disable_login_form` setting does not protect against API access.

---

### CRIT-4 — Hardcoded Admin Password in Version Control **(carry-over from #566, unresolved)**

**File:** `argocd/config/regional-cluster/grafana/values.yaml` line 28

```yaml
adminPassword: "admin"  # Static password prevents ArgoCD out-of-sync diffs.
```

**Risk:** The password `admin` is permanently in git history and is trivially guessable. While the login form is currently disabled, any future configuration change that re-enables it (ArgoCD rollback, manual edit, Helm upgrade regression) exposes the admin account with a known credential. The comment itself documents that this is an architectural compromise rather than a security control.

**What to mitigate:** Replace the hardcoded password with an ExternalSecret referencing a secret stored in AWS Secrets Manager. ArgoCD's sync behavior can be managed by marking the password field with `argocd.argoproj.io/compare-options: IgnoreExtraneous`.

---

## HIGH Findings

### HIGH-1 — CI Containerfile Installs AWS CLI Without GPG Signature Verification **(NEW)**

**File:** `ci/Containerfile`

```dockerfile
RUN ... curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" -o "awscliv2.zip" && \
    unzip -qo awscliv2.zip && \
    ./aws/install
```

**Risk:** The CI Containerfile downloads the AWS CLI but skips the GPG signature verification step. Compare with `aws-nuke-cf/Containerfile`, which correctly does:
```dockerfile
gpg --keyserver keyserver.ubuntu.com --recv-keys FB5DB77FD5C118B80511ADA8A6310ACC4672475C && \
gpg --verify awscliv2.zip.sig awscliv2.zip
```

Without GPG verification, a MITM attacker or a compromised CDN edge node serving `awscli.amazonaws.com` could substitute a malicious AWS CLI binary. The CI container runs with AWS credentials in every CI pipeline job.

**Attack vector:** MITM between the build host and `awscli.amazonaws.com` (possible in some CI/CD network configurations, corporate proxies, or CDN cache poisoning) serves a trojanized AWS CLI binary. When CI jobs run with AWS credentials, the malicious CLI exfiltrates them.

**What to mitigate:** Follow the same pattern as `aws-nuke-cf/Containerfile`: download the `.sig` file, import the AWS GPG signing key, and verify with `gpg --verify` before installing.

---

### HIGH-2 — CI Containerfile Installs yq Without Checksum Verification **(NEW)**

**File:** `ci/Containerfile`

```dockerfile
RUN ... curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
```

**Risk:** The `yq` binary is downloaded and installed directly from GitHub releases without any checksum verification. Every other tool in this Containerfile (Terraform, Helm, k6, promtool, AWS CLI) includes checksum verification. The `yq` download is the only exception, creating a supply chain gap.

**Attack vector:** A compromised GitHub release or a MITM serving a modified `yq` binary would be silently installed and executed with the permissions of the CI build environment.

**What to mitigate:** Add SHA256 verification:
```dockerfile
curl -fsSL "${YQ_BASE}/${YQ_VERSION}/checksums-bsd" | grep "yq_linux_${YQ_ARCH}" | sha256sum -c -
```
Or download the GitHub-provided checksums file and verify before installation.

---

### HIGH-3 — CI Containerfile Base Image Uses Unpinned `:latest` Tag **(carry-over, unresolved)**

**File:** `ci/Containerfile` line 1

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi:latest
```

**Risk:** The `:latest` tag is a mutable pointer. A security issue in a newly pushed UBI9 image, or a supply chain compromise of the registry, would silently affect all subsequent CI builds. The CI image runs with AWS credentials — a compromised base layer gains access to those credentials.

**What to mitigate:** Pin to a specific SHA256 digest:
```dockerfile
FROM registry.access.redhat.com/ubi9/ubi@sha256:<hash>
```

---

### HIGH-4 — IoT Policy Allows Wildcard Client IDs — Any Certificate Holder Can Impersonate Any Management Cluster Agent **(NEW)**

**File:** `terraform/modules/maestro-agent-iot-provisioning/main.tf` lines ~53–57

```hcl
{
  Effect = "Allow"
  Action = ["iot:Connect"]
  Resource = [
    "arn:aws:iot:...:client/*"
  ]
}
```

**Risk:** The IoT Connect policy grants connection permission to `client/*` — any client ID. The AWS IoT Core security model uses client IDs to identify connecting devices. If a Maestro Agent certificate is leaked or stolen, the attacker can connect using **any** client ID, including IDs belonging to other management clusters. This could allow:
1. Impersonation of a different management cluster in the MQTT messaging topology.
2. Cross-cluster message injection (if downstream consumers trust the client ID for routing).

**What to mitigate:** Restrict the Connect resource to the specific management cluster's client ID:
```hcl
"arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:client/${var.management_cluster_id}-*"
```

---

### HIGH-5 — IoT Root CA Fetched from External URL at Terraform Plan Time **(NEW)**

**File:** `terraform/modules/maestro-agent-iot-provisioning/main.tf` lines ~27–29

```hcl
data "http" "aws_iot_root_ca" {
  url = "https://www.amazontrust.com/repository/AmazonRootCA1.pem"
}
```

**Risk:** The Terraform `http` data source fetches the AWS IoT Root CA certificate from `amazontrust.com` at every `terraform plan` and `terraform apply`. This creates:
1. A runtime dependency on external HTTP infrastructure being available.
2. A potential supply chain risk: if DNS for `amazontrust.com` is poisoned, or if the certificate chain at that URL changes, a malicious CA could be injected into the IoT trust store.
3. No pinning or integrity verification of the fetched content.

**What to mitigate:** Embed the Amazon Root CA 1 PEM directly as a Terraform variable or local file (it's a static, versioned certificate). The certificate is published with specific validity dates and doesn't change frequently. Verify any update against the official fingerprint before embedding.

---

### HIGH-6 — ECS Bootstrap Task Role Has Permanent Cluster-Admin Access to EKS **(NEW)**

**File:** `terraform/modules/ecs-bootstrap/iam.tf` lines ~80–95

```hcl
resource "aws_eks_access_policy_association" "bootstrap_cluster_admin" {
  cluster_name  = var.eks_cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_iam_role.task.arn
  access_scope { type = "cluster" }
}
```

**Risk:** The bootstrap task role is granted `AmazonEKSClusterAdminPolicy` with cluster-wide scope. This role is associated with the EKS cluster **indefinitely** after bootstrap completes. Any actor who can assume this IAM role has full Kubernetes cluster-admin access to the EKS cluster at any time — not just during the bootstrap window.

**Attack vector:** An attacker who gains access to ECS or can create new ECS task definitions referencing the bootstrap task role (if ECS permissions are overly broad) gets full Kubernetes cluster-admin access.

**What to mitigate:** Revoke or remove the EKS access entry for the bootstrap role after bootstrap completes. This could be implemented as a cleanup step in the bootstrap script itself, or as a Terraform lifecycle rule that removes the access entry after a time-to-live.

---

## MEDIUM Findings

### MED-1 — uv Installer Script Runs Without Pre-Verification **(NEW)**

**File:** `ci/Containerfile`

```dockerfile
RUN curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" -o /tmp/uv-install.sh && \
    UV_UNMANAGED_INSTALL=/usr/local/bin sh /tmp/uv-install.sh
```

**Risk:** The uv installer script is downloaded and executed without any verification of its content or signature. While the uv project does provide checksum files, the install script itself is not verified. A compromised `astral.sh` domain or a MITM serving a modified install script would silently compromise the CI build environment.

**What to mitigate:** Download the uv binary directly (not the install script) and verify it against the published SHA256 checksums:
```dockerfile
curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" -o uv.tar.gz && \
curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz.sha256" | sha256sum -c -
```

---

### MED-2 — Helm Install Script Downloaded and Executed Without Verification **(carry-over, unresolved)**

**File:** `ci/Containerfile`

```dockerfile
RUN curl -fsSL "https://raw.githubusercontent.com/helm/helm/${HELM_VERSION}/scripts/get-helm-3" \
    | DESIRED_VERSION="${HELM_VERSION}" VERIFY_CHECKSUM=true bash
```

**Risk:** The Helm install script is piped directly to bash without verifying the script itself. Even with `VERIFY_CHECKSUM=true` (which verifies the Helm binary), the script that performs the verification could be tampered with if the GitHub raw content delivery is compromised. The script runs with root privileges in the build container.

**What to mitigate:** Download the Helm binary directly from the GitHub releases page, verify the SHA256 checksum and GPG signature before running, following the same pattern used for Terraform in this Containerfile.
