# Configure Platform API authorization

Authorization is mandatory and denies customer operations by default. Account
enrollment grants no permissions. The generic chart defaults to deny-all;
platform source config explicitly grants the provisioning role ManagementCluster operations only.

**Pin a compatible API image before rollout.** The feature branch pins commit
`7d07ffac9a66bb8b4a0de1447cc25e26d74335d0` at verified digest
`sha256:925a54424f766288b009029aebe2e0a6068c4345eda9da987c74232be58e3a45`.
Konflux built this revision with the service-operator authorization model.
Rendering and image builds do not prove deployment; provisioning and real IAM
trust verification belong to ROSAENG-67493.

## Deployment identity trust gap

**Gateway-only access is a required prerequisite and remains unproven.** The API trusts
`X-Amz-Account-Id` and `X-Amz-Caller-Arn` without authenticating their source.
Admission validates the ARN/account pair and enrollment, not who sent the headers.

The chart exposes raw API port 8000 through a ClusterIP Service, alongside
Envoy HTTP port 8080. Neither listener authenticates these headers, so a direct caller can impersonate an
enrolled identity. A private ClusterIP alone does not prevent this.

The local HTTP runner injects headers only on loopback listeners, setting
`API_BIND_ADDRESS`, `HEALTH_BIND_ADDRESS`, and `METRICS_BIND_ADDRESS` to
`127.0.0.1`; deployed defaults remain `0.0.0.0`. Local tests do not establish the
shared-deployment trust boundary. Local-only loopback proof is not permission for shared rollout.

## Set the bundle

Set `applications.regional-cluster.platformApi.authz` in
`config/<environment>/defaults.yaml` or `config/<environment>/<region>.yaml`.
The renderer passes it to `platformApi.authz` in the regional Helm values.
`config` is a serialized YAML string, not a nested values object.

```yaml
applications:
  regional-cluster:
    platformApi:
      authz:
        config: |
          formatVersion: 1
          registeredAccounts: []
          policies: []
          attachments: []
```

This complete replacement denies all operations, including provisioning. Bundle rules:

- `formatVersion` is the integer `1`.
- `registeredAccounts` contains quoted 12-digit AWS account IDs.
- Each policy has a stable `id`, quoted `ownerAccountID`, and `content` containing
  one ordinary Cedar statement. Use `permit` or `forbid`, not a template slot.
- Each attachment has a stable `id`, `policyID`, full `principalARN`,
  and `scope`. Its account must match the policy owner.
- `scope` is `global` or `regional`. Include `region` only for regional scope.
- Optional `serviceOperatorPolicies` and `serviceOperatorAttachments` must appear
  together as lists, with the same record shapes as customer policies/attachments.
  References stay within their domain. Customer policies (including `AllActions`
  or policy-admin status) never grant ManagementCluster access; service policies
  never grant customer operations. Missing service lists grant no MC access.

Authorization requires a configuration file.
Before serving, the API rejects malformed bundles, unknown fields/versions,
duplicate IDs, invalid accounts/ARNs, dangling references, ambiguous role aliases,
and invalid policies/bindings. Chart input checks do not replace API validation.

### Configure provisioning permissions

Supply one complete version-1 bundle. Helm does not generate or merge grants.
The API rejects version-2 wrappers. `serviceOperatorRoleNames` is no longer
supported; move each role's grants into the bundle before rollout.

`config/defaults.yaml` explicitly grants the configured child-admin role
`CreateManagementCluster`, `ListManagementClusters`, and `DescribeManagementCluster`.
Stage uses `rosa-hyperfleet-account-admin`; ephemeral and integration use their
configured child-admin role. A replacement `authz.config` must include equivalent
permissions if that deployment provisions management clusters.

For example, this bundle authorizes only the provisioning role:

```yaml
formatVersion: 1
registeredAccounts: ["@@AWS_ACCOUNT_ID@@"]
policies: []
attachments: []
serviceOperatorPolicies:
  - id: provision-management-clusters
    ownerAccountID: "@@AWS_ACCOUNT_ID@@"
    content: |
      permit(principal, action in [HyperFleet::Action::"CreateManagementCluster", HyperFleet::Action::"ListManagementClusters", HyperFleet::Action::"DescribeManagementCluster"], resource);
serviceOperatorAttachments:
  - id: regional-provisioner
    policyID: provision-management-clusters
    principalARN: arn:aws:iam::@@AWS_ACCOUNT_ID@@:role/{{ child_admin_role_name }}
    scope: regional
    region: "@@AWS_REGION@@"
```

The Python renderer resolves `child_admin_role_name` from configuration. At deployment,
Helm replaces `@@AWS_ACCOUNT_ID@@` and `@@AWS_REGION@@` with bootstrap's trusted
`global.aws_account_id` and `global.aws_region`. Account substitution requires a
12-digit string; region substitution requires a valid service-region string.
Literal bundles require neither substitution. No YAML parsing or reserialization
occurs in Helm, so duplicate keys and malformed records reach API validation intact.
Duplicate accounts, domain-local IDs, dangling references, or ambiguous role aliases fail startup.

These substitutions support stable deployments whose account is still an SSM
reference during Python rendering. Ephemeral provisioning and resync query STS
for the actual RC and MC accounts before rendering. The ephemeral bundle uses the
resolved RC account and configured role, including custom pools, without a seed
wrapper. CI ephemeral rendering requires a resolved 12-digit RC account; previews
with unresolved accounts fail before producing deployment config. The enrollment
list avoids duplicating RC accounts already enrolled for CI.
Provisioning authenticates as the RC role; the MC hosting account in the registration
payload is not the caller's account.

Custom environment overrides replace the entire serialized bundle. Include
service grants for the actual RC caller and separately verified customer grants.
Changing either the bundle or substituted identity changes the ConfigMap checksum.

`scripts/buildspec/register.sh` assumes the configured child-admin role even in
the central CodeBuild account; other operations retain their same-account shortcut.
Missing roles or failed trust are fatal, without ambient-credential fallback.
This config creates no IAM trust. Verify actual assumption during ROSAENG-67493.

The deployed API E2E suite keeps `rrp-rc` for customer-resource operations.
ManagementCluster checks use `E2E_SERVICE_OPERATOR_PROFILE`. The default regional
signer can also have explicit service grants in local dev; customer-only denial
is verified by the local authorization HTTP suite. When the operator profile is
unset, the runner copies the AWS config into its
scratch directory and adds `rrp-service-operator`, assuming the regional
`OrganizationAccountAccessRole` from `rrp-central`. CI provisioning establishes
that trust. Other environments must supply an explicitly granted operator profile.
Failed assumption fails the suite without falling back to customer credentials.

`ci/e2e-platform-api-test.sh` requires already-assumed operator credentials in
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN`.
It uses curl SigV4 and requires transport success plus HTTP 201 or the API's typed
409 Status/Conflict with code 409 and `MC-MGMT-CREATE-005:` message prefix.
Authorization/gateway errors fail. Pass the complete invoke base, including its
stage; the script appends `/api/v0/...` once and sends `{id, region, accountId}`
with the current caller account. It neither manages credentials nor tests the
obsolete resource_bundles route.

## Select applicable attachments without rewriting policies

Use generic `principal` when attachment matching determines applicability. The API
validates each attachment for the caller and trusted service region, then evaluates
its original policy unchanged in a request-local set for that fixed identity.
There is no principal AST rewrite or `?principal` text replacement.

- IAM user and STS assumed-role session ARNs match only that exact caller.
- IAM role attachments match supported assumed-role sessions and add the configured
  role as an entity parent. The session ARN remains the request principal.

Authored equality stays equality, not membership, and can still deny a child
session. The `binding` error stage remains attachment validation, not AST linking.

STS session ARNs omit IAM role paths. The resolver matches partition, account,
and final role name without an IAM lookup; only commercial `arn:aws` is supported.
Keep full IAM role ARNs, but do not configure distinct paths with the same account
and final role name across either policy domain. STS cannot distinguish them;
ambiguous aliases fail startup.

The API owns its fixed `HyperFleet` schema. See the sibling repository's
`rosa-hyperfleet-api/docs/authz.md` for operation/group permissions, protected
updates, trusted context/parent identity, filtered collections and CAS limits.
The bundle supplies policies, not a custom schema or a storage-isolation bypass.

Stored Kubernetes metadata labels are Cedar entity tags of type `String`.
They are not AWS tags or Cluster `spec.tags`. Guard reads of optional keys:

```cedar
permit(principal,
  action == HyperFleet::Action::"DescribeCluster",
  resource is HyperFleet::Cluster)
when {
  resource.hasTag("example.com/team") &&
  resource.getTag("example.com/team") == "blue"
};
```

The capability gate pins `cedar-go v1.8.0`. Schema validation uses experimental
`x/exp/schema`, `x/exp/schema/resolved`, `x/exp/schema/validate`, and `x/exp/ast`
imports. Parsing alone is not validation.

## Seed verified local callers

The [dev override example](examples/authz-dev/defaults.yaml) enrolls RC
`599476212575` and customer `114594328247`. Each gets regional customer
`AllActions` through its child-admin role (currently `OrganizationAccountAccessRole`),
restricted to the owning account and `us-east-1`. ManagementCluster provisioning
uses explicit service-operator records in the same bundle.

The IDs come from the sibling internal repository's `infra/accounts/dev/accounts.json`;
`scripts/dev/ephemeral-env.sh` configures the roles. Custom `RRP_ACCOUNTS_DEV` files
or preset profiles require a verified bundle for their actual callers.

Copy both example files into the ignored `.ephemeral-env/` directory. Review and
merge existing overrides first; do not overwrite their settings.

```sh
mkdir -p .ephemeral-env
cp -n docs/examples/authz-dev/*.yaml .ephemeral-env/
```

The provider deep-merges override defaults into `config/ephemeral/defaults.yaml`
and replaces region files with the overrides, including the example's
`us-east-1.yaml`. Copying files does not provision or deploy anything.

`config/ephemeral/defaults.yaml` serves both dev0 and ci00. On this feature branch,
its customer bundle grants regional `AllActions` lifecycle access to the verified local
`OrganizationAccountAccessRole` roles in RC `720644165472` and customer
`313828097858`. These accounts match the internal repository's CI onboarding
records. The grants render only when `ci` is true (both `EPH_PREFIX` and `BUILD_ID`
are set during ephemeral CI provisioning). Dev rendering and ordinary CI lint
retain empty customer enrollment and grants. Integration and stage remain empty
in the customer domain. The same complete bundle explicitly grants the configured
runtime RC role service operations and enrolls that RC account for admission.

These are verified local roles, not a claim about Prow's Vault credential chain.
The bundle also attaches the regional customer lifecycle policy to
`arn:aws:iam::720644165472:user/e2e` as an exact-user attachment, matching the
caller observed in Prow run `2106095188232376320`. It attaches the customer lifecycle
policy to `arn:aws:iam::313828097858:user/rrp-hcp-customer`, observed in Prow run
`2107129561895407616`, with the same exact-user matching and regional scope. The E2E runner
logs the actual regional caller and, when customer tests run, the customer
caller's account and ARN. If Prow uses different principals, requests
fail closed; update explicit attachments only after inspecting that evidence.
Profile names alone are not caller proof. Injected infrastructure account IDs do
not automatically become enrolled callers. Review these feature-branch grants
before merging or using another account pool.

## Render and inspect

Generate deployment values through the renderer only:

```sh
uv run scripts/render.py
```

Inspect `deploy/<environment>/<region>/argocd-values-regional-cluster.yaml`.
Render the chart with those values and the region supplied by the ApplicationSet:

```sh
# Supply the actual verified RC account; do not copy a placeholder or guessed ID.
helm template platform-api argocd/config/regional-cluster/platform-api --set global.aws_region=us-east-1 --set-string global.aws_account_id="$RC_ACCOUNT_ID" -f deploy/ephemeral/us-east-1/argocd-values-regional-cluster.yaml
```

The chart sets `AUTHZ_CONFIG_FILE=/etc/platform-api/authz/config.yaml`.
The API's `--authz-config-file` flag overrides that environment value.
Configuration is the only supported policy source; no source selector is exposed.

The `authz-config` ConfigMap mounts read-only at `/etc/platform-api/authz`, mode
`0644`, readable by UID/GID 65534. Authorization has no enable switch; the separate
rate-limit ConfigMap, mount, and checksum depend on `platformApi.rateLimit.enabled`.

## Replace configuration by restart

The API loads an immutable bundle at startup: changes require restart, with no
watcher or reload API. The rollout annotation hashes the complete authz ConfigMap,
including metadata and whitespace; any change triggers a new pod template.

Invalid replacements fail startup, never fall back to permissive access. Old
replicas retain their old bundle during rollout, so the checksum does not guarantee
instantaneous revocation or a global snapshot.

## Interpret authorization metrics

Collectors use the API's default Prometheus registry. The Service exposes named
port `metrics` (default 9090); its ServiceMonitor scrapes `/metrics` in the API
namespace. Chart checks do not prove deployed Prometheus/Thanos collection.

| Metric                   | Type      | Unit            | Labels                 |
| ------------------------ | --------- | --------------- | ---------------------- |
| `authz_requests_total`   | Counter   | requests        | `operation`, `outcome` |
| `authz_duration_seconds` | Histogram | seconds         | `operation`, `outcome` |
| `authz_failures_total`   | Counter   | failed requests | `operation`, `stage`   |

- `operation` is a bounded concrete action name for Cluster, NodePool, OIDCConfig,
  or ManagementCluster; changed-field checks share the same request sample.
- `outcome` is only `allow`, `deny`, or `error`.
- Error `stage`: `resolution`, `parsing`, `binding`, `entity_validation`,
  `evaluation`, or `resource_loading`.

Labels contain no caller/resource/policy identifiers, URLs, or arbitrary errors.
Each authorization attempt increments the request counter and observes the
histogram once. Only `error` increments the failure counter, once at its first
terminal failure stage. Count attempts with
`sum by (operation) (authz_requests_total)`, not HTTP statuses or per-item evaluations.

The histogram has cumulative buckets in seconds at `0.001`, `0.005`, `0.01`,
`0.025`, `0.05`, `0.1`, `0.25`, `0.5`, and `1`, plus the automatic `+Inf` bucket.
Exposition adds `_bucket` with the `le` boundary label, `_sum` in seconds, and
`_count` in observations. The 50 ms bucket is not a latency SLO.

Timing includes resolution, parsing, binding, entity construction and validation,
evaluation, and required account-scoped FleetDB reads. It excludes identity and
enrollment admission, rate limiting, response conversion and serialization, and
socket delivery. This is
authorization-path duration, not engine-only time or end-to-end HTTP latency.

The handlers apply these accounting rules:

- A successful filtered list records one `allow`, even when some or all items
  receive ordinary denials. Every candidate is checked before totals and paging.
- A collection denial or a DescribeCluster object denial records one `deny`
  and returns 403.
- A missing or foreign Cluster returns 404 and records one `deny` once the
  attempt starts. Account-scoped lookup does not reveal foreign existence.
- A late item failure aborts the whole list and records one `error` at its
  failure stage, even for an item beyond the requested page. No partial success
  or earlier per-item allow sample is emitted.
- A storage-read failure preserves its API error and records one `error` at
  `resource_loading`.
- A response-write failure after authorization does not revise an `allow`.

Admission failures, rate-limited 429s, health/readiness/info, and metrics scrapes
produce no authorization samples. Unmapped routes produce no authorization samples.
All implemented non-label
operations on the four resource families are mapped; AccessEntry, labels, and
policy-management APIs are not added. Missing samples do not prove enforcement.

Run the focused source and Helm checks with the CI-pinned Helm CLI on `PATH`:

```sh
uv run scripts/test_render.py
uv run --with pytest python -m pytest -q scripts/test_platform_registration.py
```
