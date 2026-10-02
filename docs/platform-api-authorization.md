# Configure Platform API authorization

This chart delivers a mandatory startup authorization bundle. Global and chart
values deny protected reads by default. Enrollment alone grants no action.

The feature branch pins the API image built from commit
`e6610c5ca12c0bfd776452055d82d59d0b5e64bc` by digest. Rendering is not a
server-startup or shared-deployment proof.

## Deployment identity trust gap

The API copies `X-Amz-Account-Id` and `X-Amz-Caller-Arn` headers into request
context without authenticating their source. Admission validates the ARN/account
pair and enrollment, not who supplied the headers. These values are trusted only
when a verified gateway-only path prevents direct backend callers.

The current chart exposes raw API port 8000 through a ClusterIP Service as well
as Envoy HTTP port 8080. Envoy forwards requests without authenticating these
identity headers. A caller that reaches either port can supply an enrolled
identity. Gateway-only access is a required prerequisite and remains unproven.
A private ClusterIP alone does not establish that boundary.

The local HTTP runner injects headers only on isolated listeners. It sets
`API_BIND_ADDRESS`, `HEALTH_BIND_ADDRESS`, and `METRICS_BIND_ADDRESS` to
`127.0.0.1`. Deployed defaults remain `0.0.0.0`.
Local-only loopback proof is not permission for shared rollout. Network or
Terraform changes are outside this documentation task.

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
        resolver: config
        config: |
          formatVersion: 1
          registeredAccounts: []
          policies: []
          attachments: []
```

Keep the following bundle rules:

- `formatVersion` is the integer `1`.
- `registeredAccounts` contains quoted 12-digit AWS account IDs.
- Each policy has a stable `id`, quoted `ownerAccountID`, and `content` containing
  one ordinary Cedar statement. Use `permit` or `forbid`, not a template slot.
- Each attachment has a stable `id`, `policyID`, full `principalARN`,
  `bindingMode`, and `scope`. Its account must match the policy owner.
- `bindingMode` is `exact-principal` or `role-membership`.
- `scope` is `global` or `regional`. Include `region` only for regional scope.

The API accepts only the `config` resolver and requires a configuration file.
The API contract rejects malformed bundles, unknown fields or versions,
duplicate IDs, invalid accounts or ARNs, dangling references, ambiguous role
aliases, and invalid policies or bindings before serving traffic. The chart
requires nonempty resolver and bundle inputs. It does not replace API validation.

## Bind principals without widening policies

Write generic `principal` policies when attachment binding supplies the caller
constraint. The API binds a fresh AST for each attachment and adds a constraint.
It preserves the statement's original effect, scopes, conditions, and annotations.
There is no `?principal` text replacement.

Use `exact-principal` for a user or one assumed-role session. The loader rejects
`exact-principal` attachments to IAM roles. Use explicit `role-membership` for
inherited role grants. The actual session ARN remains the request principal.
An original equality constraint remains equality, not membership, and can still
deny a child session.

Assumed-role session ARNs omit the IAM role path. The local resolver matches
configured roles by partition, account, and role name. Keep the original full
role ARN, including its path. Ambiguous aliases must fail startup. This model
has no IAM lookup on the request path.

The API embeds one fixed `HyperFleet` schema. The bundle supplies no custom
schema. It maps `ListClusters` to `Collection` and `DescribeCluster` to `Cluster`.
Both actions belong to `ReadOnly`. Trusted request context provides
`region`, `accountId`, and `principalArn`. Do not supply these through request
bodies or query parameters. FleetDB account isolation remains independent of
Cedar permissions.

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

The [dev override example](examples/authz-dev/defaults.yaml) enrolls only RC
`599476212575` and customer `114594328247`. Each account gets one regional
`ReadOnly` policy attached by membership to its `OrganizationAccountAccessRole`.
The policy restricts trusted context to its owning account and `us-east-1`.
It grants no ManagementCluster or service-operator operation.

These IDs come from the sibling internal repository's
`infra/accounts/dev/accounts.json`. The default dev script configures both roles
in `scripts/dev/ephemeral-env.sh`. Custom `RRP_ACCOUNTS_DEV` files or preset AWS
profiles require their own verified bundle.

To prepare an explicit local ephemeral override, copy both example files into
the ignored `.ephemeral-env/` directory. Review any existing overrides first.
Do not overwrite them without merging their settings.

```sh
mkdir -p .ephemeral-env
cp -n docs/examples/authz-dev/*.yaml .ephemeral-env/
```

The existing ephemeral provider deep-merges `.ephemeral-env/defaults.yaml` into
`config/ephemeral/defaults.yaml` and replaces its region files with the override
region files. The example includes `us-east-1.yaml` for that path. Preparing
these files does not provision or deploy anything.

`config/ephemeral/defaults.yaml` serves both dev0 and ci00. On this feature branch,
its bundle grants regional `ReadOnly` access to the verified local
`OrganizationAccountAccessRole` roles in RC `720644165472` and customer
`313828097858`. These accounts match the internal repository's CI onboarding
records. The grants render only when `ci` is true (both `EPH_PREFIX` and `BUILD_ID`
are set during ephemeral CI provisioning). Dev rendering and ordinary CI lint
retain empty enrollment and grants. Integration and stage remain empty.

These are verified local roles, not a claim about Prow's Vault credential chain.
The E2E runner logs the actual regional caller and, when customer tests run, the
customer caller's account and ARN. If Prow uses different principals, requests
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
helm template platform-api argocd/config/regional-cluster/platform-api --set global.aws_region=us-east-1 -f deploy/ephemeral/us-east-1/argocd-values-regional-cluster.yaml
```

The chart sets `AUTHZ_RESOLVER=config` and
`AUTHZ_CONFIG_FILE=/etc/platform-api/authz/config.yaml`. The corresponding API
flags are `--authz-resolver` and `--authz-config-file`. Explicit flags take
precedence over environment values under the API startup contract.

The `authz-config` ConfigMap mounts read-only at `/etc/platform-api/authz`.
Its explicit mode `0644` permits reads by UID/GID 65534 without ownership changes.
There is no authorization enable switch. The independent rate-limit ConfigMap,
mount, and checksum remain conditional on `platformApi.rateLimit.enabled`.

## Replace configuration by restart

The API contract loads one immutable bundle at startup and requires a restart
for changes. The rollout annotation hashes the complete authz ConfigMap,
including metadata and all bundle bytes. Account, policy, attachment, and
whitespace changes trigger a new pod template. There is no watcher or reload API.

Invalid replacement configuration must fail startup, not fall back to permissive
access. During a multi-replica rollout, old replicas can still use the old bundle.
The checksum is not an instantaneous revocation guarantee or a global snapshot.

## Interpret authorization metrics

The API registers these collectors once with its existing default Prometheus
registry. The metrics container and Service use the named `metrics` port,
default 9090. The existing ServiceMonitor selects that Service in the API
namespace and scrapes `/metrics`. Chart checks do not prove collection by
deployed Prometheus or Thanos.

| Metric                   | Type      | Unit            | Labels                 |
| ------------------------ | --------- | --------------- | ---------------------- |
| `authz_requests_total`   | Counter   | requests        | `operation`, `outcome` |
| `authz_duration_seconds` | Histogram | seconds         | `operation`, `outcome` |
| `authz_failures_total`   | Counter   | failed requests | `operation`, `stage`   |

`operation` is only `ListClusters` or `DescribeCluster`.
`outcome` is only `allow`, `deny`, or `error`.
For errors, `stage` is only `resolution`, `parsing`, `binding`,
`entity_validation`, `evaluation`, or `resource_loading`.
Use the underscores exactly as shown. A denial is not a failure-counter event.
Labels contain no URLs, account IDs, ARNs, policy IDs, attachment IDs, resource
IDs, or arbitrary error text.

Each attempted read records one terminal request-counter increment and one
histogram observation. An `error` also increments the failure counter once at
its first terminal failure stage. Sum outcomes to obtain attempts with
`sum by (operation) (authz_requests_total)`, not HTTP status counts or per-item
Cedar evaluations.

The histogram has cumulative buckets in seconds at `0.001`, `0.005`, `0.01`,
`0.025`, `0.05`, `0.1`, `0.25`, `0.5`, and `1`, plus the automatic `+Inf` bucket.
Exposition adds `_bucket` with the `le` boundary label, `_sum` in seconds, and
`_count` in observations. The 50 ms bucket is not a latency SLO.

Timing starts immediately before request preparation in an admitted Cluster
read handler and stops at its terminal authorization result. It includes
resolution, parsing, binding, entity construction and validation, evaluation,
and required account-scoped FleetDB reads. It excludes identity and enrollment
admission, rate limiting, response conversion and serialization, and socket
delivery. This is authorization-path duration, not Cedar-engine-only time or
end-to-end HTTP latency.

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

Missing or invalid identity, failed enrollment, rate-limited 429 responses,
health, readiness, info, and metrics scrapes produce no authorization samples.
Unmapped routes produce no authorization samples. Cluster writes and other
resource routes remain unmapped in this proof. Absence of samples is not proof
of Cedar enforcement or permission for shared rollout.

Run the focused source and Helm checks with the CI-pinned Helm CLI on `PATH`:

```sh
uv run scripts/test_render.py
```
