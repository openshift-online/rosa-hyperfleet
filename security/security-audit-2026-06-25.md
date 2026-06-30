# Security Audit Report

**Date:** 2026-06-25  
**Scan Mode:** Full Project Audit  
**Tech Stack:** Terraform, EKS, Kubernetes/Helm, Shell, Python, ArgoCD, AWS (API Gateway, RDS, IoT, S3, KMS)  
**Files Reviewed:** ~600  
**Domains Analyzed:** Infrastructure/IaC, Containers, Kubernetes, CI/CD, Secrets, Cloud Native, Supply Chain, Git/GitHub

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 8 |
| LOW | 3 |

---

## Findings

### HIGH

#### 1. No VPC Flow Logs Enabled

- **File:** `terraform/modules/vpc/main.tf`
- **Category:** Infrastructure — Network Monitoring
- **Issue:** The VPC module defines VPC endpoints and security groups but has no `aws_flow_log` resource. VPC flow logs are essential for network traffic visibility, intrusion detection, and incident investigation.
- **Impact:** Without flow logs, there is no record of accepted/rejected network connections. An attacker performing lateral movement or data exfiltration within the VPC would leave no network-level audit trail. This is also a gap for FedRAMP AU-12 (Audit Generation) which requires capturing network traffic events.
- **Remediation:**
  1. Add `aws_flow_log` resource to `terraform/modules/vpc/main.tf` sending to CloudWatch Logs (KMS-encrypted, matching the project's pattern for other log groups).
  2. Verify flow logs appear in CloudWatch after apply.
  3. Add a CI check or Terraform sentinel policy requiring `aws_flow_log` in VPC modules.
  4. Consider also enabling flow logs at the subnet level for finer-grained visibility. Gate behind `enable_vpc_flow_logs` flag defaulting to `true`.

---

#### 2. No Kubernetes NetworkPolicies

- **File:** `argocd/config/` (all charts)
- **Category:** Kubernetes — Network Segmentation
- **Issue:** Zero `NetworkPolicy` resources found across all ArgoCD Helm chart configurations for both Regional Clusters and Management Clusters. Without NetworkPolicies, any pod can communicate with any other pod in the same cluster unrestricted.
- **Impact:** If any pod is compromised (e.g., through a container vulnerability), the attacker has unrestricted network access to all other pods including control plane services (Maestro, CLM, ArgoCD), databases, and internal APIs. This violates the principle of least privilege at the network layer.
- **Remediation:**
  1. Define default-deny NetworkPolicies for each namespace, then add allow rules for required traffic flows (e.g., platform-api → maestro-server → RDS).
  2. Start with a monitoring/audit-only mode using Calico or Cilium network policy logging before enforcing.
  3. Add NetworkPolicy templates to critical charts: `maestro-server`, `platform-api`, `hyperfleet-api-chart`, `hyperfleet-sentinel-chart`.
  4. Test with `kubectl describe networkpolicy` and connectivity tests between pods.

---

#### 3. CI Container Image Runs as Root

- **File:** `ci/Containerfile`
- **Category:** Containers — Privilege
- **Issue:** The CI build-root image has no `USER` instruction. All CI tasks (Terraform, Helm, tests) execute as UID 0 inside the container. While the image does create cache directories with `chmod 777` for OpenShift random-UID compatibility (line 186), the image itself defaults to root.
- **Impact:** If a CI pipeline is compromised (e.g., through a malicious PR that escapes the build sandbox), the attacker has root inside the container, maximizing the blast radius. Combined with the `awscurl` and AWS CLI tools present in the image, this could lead to credential theft.
- **Remediation:**
  1. Add `USER 65534` (nobody) or a dedicated CI user at the end of the Containerfile (matching the pattern in `platform-image/Dockerfile`).
  2. Verify CI jobs still work — the existing `chmod 777` cache directories should accommodate this.
  3. If root is required for specific operations, use a multi-stage build where tools are installed as root but the runtime stage runs as non-root.

---

### MEDIUM

#### 4. Unpinned Container Base Images

- **File:** `ci/Containerfile:5`, `images/zoa-tools/Dockerfile:1`
- **Category:** Supply Chain — Container Images
- **Issue:** Two of three Dockerfiles use `:latest` tags for base images: `registry.access.redhat.com/ubi9/ubi:latest` and `ubi9/ubi-minimal:latest`. The third (`platform-image/Dockerfile`) correctly pins to `ubi9/ubi-minimal:9.7-1770267347`.
- **Impact:** A compromised or broken `:latest` tag could silently introduce vulnerabilities or breaking changes into builds. For the CI image, this affects every PR check. For zoa-tools, this affects the Trusted Actions execution environment.
- **Remediation:**
  1. Pin both images to specific digest or version tags, matching the pattern in `platform-image/Dockerfile:1` (e.g., `ubi9/ubi-minimal:9.7-1770267347`).
  2. Set up Dependabot or Renovate to create PRs when new UBI versions are available.
  3. Verify by running `docker pull` with the pinned tag.

---

#### 5. Curl-Pipe-Bash for Helm Installation

- **File:** `ci/Containerfile:85-86`
- **Category:** Supply Chain — Build Pipeline
- **Issue:** Helm is installed by piping a script from `raw.githubusercontent.com` directly to bash. While the version is pinned (`HELM_VERSION`) and `VERIFY_CHECKSUM=true` is set, the script itself is fetched from a tag reference, not a commit hash. If the tag is force-pushed, a different script could be served.
- **Impact:** A supply chain attack on the Helm repository could inject malicious code into the CI build image. The checksum verification of the Helm binary mitigates the binary itself, but the installer script runs before that verification.
- **Remediation:**
  1. Pin the get-helm-3 script URL to a commit hash instead of a version tag: `https://raw.githubusercontent.com/helm/helm/<COMMIT_SHA>/scripts/get-helm-3`.
  2. Alternatively, download the Helm tarball directly (matching the Terraform installation pattern) with explicit checksum verification.
  3. Verify by comparing script hash against known-good values.

---

#### 6. Missing Pod Security Contexts (22+ Charts)

- **Files:** `argocd/config/regional-cluster/platform-api/values.yaml`, `argocd/config/regional-cluster/maestro-server/values.yaml`, `argocd/config/regional-cluster/hyperfleet-api-chart/values.yaml`, `argocd/config/shared/argocd/values.yaml`, and 18+ others
- **Category:** Kubernetes — Pod Security
- **Issue:** 22+ Helm chart values.yaml files have no explicit `securityContext` settings. Without these, pod security depends entirely on the cluster's Pod Security Standards enforcement. Only 4 charts (cloudwatch-exporter, grafana, vector, external-secrets) set proper contexts.
- **Impact:** Pods may run as root, with writable root filesystems, with all Linux capabilities, and with privilege escalation allowed — depending on namespace PSS level. This increases blast radius if a container is compromised.
- **Remediation:**
  1. Add a baseline security context to all charts:
     ```yaml
     securityContext:
       runAsNonRoot: true
       allowPrivilegeEscalation: false
       readOnlyRootFilesystem: true
       capabilities:
         drop: [ALL]
     ```
  2. Start with the most critical: `platform-api`, `maestro-server`, `hyperfleet-api-chart`, `hyperfleet-sentinel-chart`.
  3. Verify with `kubectl get pod -o jsonpath='{.spec.containers[*].securityContext}'`.
  4. Enforce via namespace-level Pod Security Standards (Restricted).

---

#### 7. Vector readOnlyRootFilesystem Disabled

- **File:** `argocd/config/regional-cluster/vector/values.yaml:34`, `argocd/config/management-cluster/vector/values.yaml:63`
- **Category:** Kubernetes — Pod Security
- **Issue:** Vector DaemonSet containers run with `readOnlyRootFilesystem: false`. The MC main Vector container correctly uses `readOnlyRootFilesystem: true` but its syslog container does not.
- **Impact:** A writable root filesystem allows an attacker who compromises the Vector container to persist malware, modify binaries, or install additional tools. Vector runs on every node as a DaemonSet, amplifying the impact.
- **Remediation:**
  1. Set `readOnlyRootFilesystem: true` and add `emptyDir` volume mounts for Vector's data/cache directories.
  2. Test log collection still works after the change.
  3. Align both RC and MC Vector configurations.

---

#### 8. Terraform Provider Version Constraints Lack Upper Bounds

- **Files:** `terraform/config/pipeline-management-cluster/versions.tf`, `terraform/config/pipeline-regional-cluster/versions.tf`, `terraform/config/dns-environment-zone/versions.tf`, and others
- **Category:** Supply Chain — Infrastructure
- **Issue:** All Terraform provider version constraints use `>=` floor-only syntax (e.g., `version = ">= 6.0"`). Without an upper bound, `terraform init` could pull a future major version with breaking changes or a compromised release.
- **Impact:** A compromised Terraform provider version (or an accidental breaking change) would be silently adopted on next `terraform init`. Lock files (`.terraform.lock.hcl`) mitigate this in practice, but they are gitignored in this repository.
- **Remediation:**
  1. Add upper-bound constraints: `version = ">= 6.0, < 7.0"` (pessimistic constraint).
  2. Alternatively, commit `.terraform.lock.hcl` files to version control (remove from `.gitignore`).
  3. Use Renovate or Dependabot for controlled provider upgrades.

---

#### 9. Security Group Egress Unrestricted to 0.0.0.0/0

- **Files:** `terraform/modules/maestro-infrastructure/rds.tf:122-128`, `terraform/modules/bastion/main.tf:89-94`, `terraform/modules/ecs-bootstrap/security-groups.tf:11-18`, `terraform/modules/hyperfleet-infrastructure/amazonmq.tf:113-116`, `terraform/modules/hyperfleet-infrastructure/rds.tf:122-125`
- **Category:** Infrastructure — Network Security
- **Issue:** Five security groups have `egress` rules allowing all protocols to `0.0.0.0/0`. While ingress rules are properly scoped, unrestricted egress allows compromised resources to communicate with arbitrary external destinations.
- **Impact:** A compromised RDS instance, bastion, or ECS task could exfiltrate data to attacker-controlled endpoints. While NAT Gateway routing provides some control, it does not restrict the destination. This is a defense-in-depth gap.
- **Remediation:**
  1. For RDS security groups: RDS rarely needs egress — remove or restrict to VPC CIDR only.
  2. For ECS bootstrap/bastion: restrict egress to specific CIDR ranges or use VPC endpoints where possible.
  3. Verify connectivity after changes with `aws ec2 describe-security-groups`.
  4. Consider using VPC endpoint policies to further restrict egress.

---

#### 10. Binary Downloads Without Checksum Verification

- **Files:** `images/zoa-tools/Dockerfile:28-45`, `terraform/modules/platform-image/Dockerfile:36-63`
- **Category:** Supply Chain — Container Build
- **Issue:** Multiple binary tools (kubectl, oc, AWS CLI, yq, k9s, stern) are downloaded via `curl` without SHA256 checksum verification. The CI Containerfile correctly verifies Terraform, k6, and promtool with checksums, but these other Dockerfiles skip verification.
- **Impact:** A man-in-the-middle attack or compromised download mirror could serve malicious binaries. For `zoa-tools`, this is especially concerning as it's the Trusted Actions execution image running on management clusters.
- **Remediation:**
  1. Add checksum verification for all binary downloads, following the pattern from `ci/Containerfile` (download checksums file, verify with `sha256sum -c`).
  2. Prioritize `zoa-tools/Dockerfile` as it runs in production.
  3. Verify by comparing downloaded checksums against upstream release pages.

---

#### 11. Unpinned Python Dependencies in CI

- **File:** `ci/Containerfile:196-198`
- **Category:** Supply Chain — Dependencies
- **Issue:** `awscurl` and `pyyaml` are installed without version pins: `uv pip install --system awscurl pyyaml`. A malicious or broken release could silently be pulled.
- **Impact:** Low, as this only affects the CI build image and the packages are well-known. However, it violates supply chain hardening best practices.
- **Remediation:**
  1. Pin versions: `uv pip install --system awscurl==0.33 pyyaml==6.0.2` (matching `platform-image/Dockerfile:31` which pins pyyaml).
  2. Generate a `requirements.txt` with hashes for maximum reproducibility.

---

### LOW

#### 12. chmod 777 on CI Cache Directories

- **File:** `ci/Containerfile:186`
- **Category:** Containers — File Permissions
- **Issue:** Cache directories (`/tmp/.uv-cache`, `/tmp/.terraform.d`, etc.) are created with `chmod -R 777`. While this enables OpenShift random-UID compatibility, it means any process in the container can read/write these caches.
- **Impact:** In a multi-tenant CI environment, another process could poison the Terraform plugin cache or UV package cache. Risk is low given CI isolation.
- **Remediation:**
  1. Use `chmod -R 775` with `chown :0` (group 0) instead — matching OpenShift's standard pattern used in `zoa-tools/Dockerfile:50-51`.
  2. Verify CI jobs still pass with the tighter permissions.

---

#### 13. Terraform Lock Files Gitignored

- **File:** `.gitignore:6`
- **Category:** Supply Chain — Infrastructure
- **Issue:** `.terraform.lock.hcl` is in `.gitignore`, preventing provider version lock files from being committed. Combined with `>=` version constraints, this means each `terraform init` could resolve different provider versions.
- **Impact:** Low in practice since CI pipelines likely pin state, but different developers could run different provider versions locally, leading to inconsistent plans.
- **Remediation:**
  1. Remove `*.terraform.lock.hcl` from `.gitignore` and commit lock files.
  2. Alternatively, enforce provider versions in CI with a `-lockfile=readonly` flag.

---

## Security Posture

**Overall Risk:** MEDIUM

### Strengths

- EKS fully private (`endpoint_public_access = false`) with all audit log types enabled
- KMS encryption with automatic key rotation on all sensitive resources (RDS, CloudWatch, S3)
- S3 buckets properly secured: public access blocked, versioning enabled, server-side encryption, lifecycle policies
- API Gateway uses AWS_IAM authorization (SigV4) — no anonymous access
- External Secrets Operator for all secret management — zero hardcoded secrets found
- No IAM wildcard `Action: *` policies
- RDS instances: private, encrypted, multi-AZ, with deletion protection
- GitHub Actions uses SHA-pinned actions (`@<commit-hash>`)
- Good `.gitignore` coverage for sensitive files
- GPG-verified Terraform installation in CI
- CloudTrail as configurable feature flag (FedRAMP AU-12)
- zoa-tools image: FIPS crypto policy, non-root user
- platform-image: non-root user (65534)
- ArgoCD HA mode with topology spread constraints

### Top Priority

Enable VPC Flow Logs and add Kubernetes NetworkPolicies — these are the largest gaps in visibility and lateral movement prevention.

### Quick Wins

| Fix | Effort |
|-----|--------|
| Pin container base images from `:latest` to specific digests | 30 min |
| Add `USER 65534` to `ci/Containerfile` | 5 min |
| Pin Python dependencies in CI Containerfile | 5 min |
| Add checksum verification to `zoa-tools/Dockerfile` binary downloads | 1 hr |
