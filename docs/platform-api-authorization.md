# Configure Platform API authorization

This repository delivers the Platform API's authorization bundle. Bundle format,
evaluation rules, actions, and metrics are defined in
`rosa-hyperfleet-api/docs/authz.md`.

Authorization is mandatory and denies by default. Enrollment grants nothing.

## Prerequisite: gateway-only access

The API trusts the `X-Amz-Account-Id` and `X-Amz-Caller-Arn` headers without
authenticating who sent them. The chart's ClusterIP Service exposes API port 8000
and Envoy port 8080, and neither checks those headers. Any caller that reaches the
pod directly can impersonate an enrolled identity. Restrict access to the API
Gateway path before shared rollout. This is unproven (ROSAENG-67493).

## Set the bundle

Set `applications.regional-cluster.platformApi.authz.config` in
`config/<environment>/defaults.yaml` or `config/<environment>/<region>.yaml`. The
value is the complete bundle as a YAML string. An override replaces the whole
bundle; nothing is merged.

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

That bundle denies everything, including ManagementCluster provisioning.

## Provisioning grants

`config/defaults.yaml` grants the RC child-admin role (`aws.child_admin_role_name`)
`CreateManagementCluster`, `ListManagementClusters`, and
`DescribeManagementCluster`, and nothing else:

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

- `{{ child_admin_role_name }}` resolves when `scripts/render.py` runs.
- `@@AWS_ACCOUNT_ID@@` and `@@AWS_REGION@@` resolve in Helm from
  `global.aws_account_id` and `global.aws_region`, because stable environments
  only know the account at deploy time. Helm fails if a used marker has no valid
  value.
- A replacement bundle must keep an equivalent grant if the environment
  provisions ManagementClusters.

`scripts/buildspec/register.sh` registers ManagementClusters as that role, even in
the central account. A missing role or failed assumption is fatal; there is no
fallback to ambient credentials. This config creates no IAM trust.

## Ephemeral environments

`config/ephemeral/defaults.yaml` serves CI and dev. It always grants the resolved
RC account's role the provisioning actions above.

- **CI** (`EPH_PREFIX` and `BUILD_ID` set): also grants `AllActions` in
  `us-east-1` to the CI callers in `720644165472` and `313828097858`. Rendering
  fails if the RC account is unresolved.
- **Dev**: grants no customer access. Every customer e2e test then fails with 403.
  To grant your dev roles, copy the example override before provisioning or
  resyncing:

```sh
mkdir -p .ephemeral-env
cp -n docs/examples/authz-dev/*.yaml .ephemeral-env/
make ephemeral-resync ID=<id>
```

The example enrolls RC `599476212575` and customer `114594328247` and grants each
`OrganizationAccountAccessRole` `AllActions` in `us-east-1`. Merge any existing
overrides first.

E2E runs ManagementCluster checks with `E2E_SERVICE_OPERATOR_PROFILE`. When unset,
`ci/setup-service-operator-profile.sh` assumes the RC
`OrganizationAccountAccessRole`; failure fails the suite.

## Render and roll out

```sh
uv run scripts/render.py
helm template platform-api argocd/config/regional-cluster/platform-api \
  --set global.aws_region=us-east-1 --set-string global.aws_account_id="$RC_ACCOUNT_ID" \
  -f deploy/ephemeral/us-east-1/argocd-values-regional-cluster.yaml
```

- The chart renders ConfigMap `authz-config`, mounts it read-only at
  `/etc/platform-api/authz/config.yaml`, and sets `AUTHZ_CONFIG_FILE`.
- Pod annotation `checksum/authz-config` hashes the ConfigMap, so any bundle
  change rolls the Deployment.
- The API reads the bundle only at startup. An invalid bundle fails startup. Old
  pods keep old permissions until replaced, so revocation is not instantaneous.
- The `platform-api` and `hyperfleet-operator` images must be pinned to the same
  API commit: both run FleetDB migrations at startup.

## Metrics

The Service exposes port `metrics` (9090) and the ServiceMonitor scrapes
`/metrics`. Metric names and labels: `rosa-hyperfleet-api/docs/authz.md`.

## Tests

```sh
uv run scripts/test_render.py
uv run scripts/test_ephemeral_authz.py
uv run --with pytest python -m pytest -q scripts/test_platform_registration.py
```

Helm-backed tests require Helm on `PATH`.
