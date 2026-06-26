# Cross-Component E2E Testing

Component repositories (e.g., `rosa-hyperfleet-api`) can run the rosa-hyperfleet e2e test suite against a full ephemeral environment with their PR-built image deployed.

## Overview

A reusable [step-registry workflow](https://github.com/openshift/release/tree/master/ci-operator/step-registry/rosa-hyperfleet/ephemeral-e2e) in `openshift/release` handles everything:

1. **Image build** — ci-operator builds the component's Docker image from the PR source
2. **Image push** — The image is copied to `quay.io/rrp-dev-ci/` using `oc image mirror` from the OCP `cli` image (public, so EKS can pull it without credentials), tagged `ci-<PR>-<BUILD_ID>`
3. **Provision** — Ephemeral environment provisioned from `rosa-hyperfleet` main, with the component's Helm values deep-merged with an inline YAML override
4. **E2E tests** — The RRP testing suite (`./ci/e2e-tests.sh`) from rosa-hyperfleet runs against the environment
5. **Teardown** — Ephemeral environment torn down (fire-and-forget)

## Workflow Steps

| Step                         | Image                | Purpose                                                              |
| ---------------------------- | -------------------- | -------------------------------------------------------------------- |
| `rosa-hyperfleet-image-push` | `ocp/4.21:cli`       | Copies CI-built image to quay.io using `oc image mirror`             |
| `rosa-hyperfleet-provision`  | `rosa-regional-platform-ci` | Calls ephemeral provider with YAML overrides, provisions environment |
| `rosa-hyperfleet-e2e`        | `rosa-regional-platform-ci` | Clones this repo, runs `./ci/e2e-tests.sh`                           |
| `rosa-hyperfleet-teardown`   | `rosa-regional-platform-ci` | Clones this repo, runs teardown                                      |

The `rosa-regional-platform-ci` image is built from `ci/Containerfile` and promoted to the CI registry on every merge to `main` of `openshift-online/rosa-hyperfleet`.

## CI Credentials

| Secret                             | Purpose                                             |
| ---------------------------------- | --------------------------------------------------- |
| `rosa-hyperfleet-dev-ci-quay-push` | Robot account for pushing to `quay.io/rrp-dev-ci/`  |
| `rosa-hyperfleet-ephemeral-creds`  | AWS credentials for provisioning, e2e, and teardown |

Managed in [Vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/cluster-secrets-rosa-hyperfleet-int/).

## Override Mechanism

The provision step deep-merges a YAML fragment into a target file in the rosa-hyperfleet repo before the ephemeral provider commits and pushes the CI branch. This is used to inject PR-built component images into Helm values files.

The override is configured via env vars in the CI config:

| Variable                           | Description                                                                                                                                                                             |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ROSA_REGIONAL_COMPONENT_NAME`     | Component name for logging (e.g., `platform-api`).                                                                                                                                      |
| `ROSA_REGIONAL_HELM_VALUES_FILE`   | Path to the target file in this repo (e.g., `argocd/config/regional-cluster/platform-api/values.yaml`).                                                                                 |
| `ROSA_REGIONAL_HELM_OVERRIDE_YAML` | Inline YAML fragment to deep-merge into the target file. Use `IMAGE_REPO` and `IMAGE_TAG` as placeholders — they are replaced with the actual image reference from the image-push step. |
| `ROSA_REGIONAL_QUAY_DEST_REPO`     | Public quay.io repository for the CI-built image.                                                                                                                                       |

The deep merge works as follows:

- **Dicts** are merged recursively (override wins on conflicts).
- **Lists of dicts** are matched by `name` key — a matching item is merged, unmatched items are appended.
- **All other values** (scalars, lists of non-dicts) are replaced by the override.

### Image override example

For a values file with this structure:

```yaml
platformApi:
  app:
    image:
      repository: quay.io/rrp/platform-api
      tag: latest
```

The inline override YAML would be:

```yaml
ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
  platformApi:
    app:
      image:
        repository: IMAGE_REPO
        tag: IMAGE_TAG
```

`IMAGE_REPO` and `IMAGE_TAG` are replaced at runtime with the actual image pushed by the image-push step.

### Chart version override example

For overriding a Helm chart dependency version in `Chart.yaml`:

```yaml
ROSA_REGIONAL_HELM_VALUES_FILE: argocd/config/management-cluster/cert-manager/Chart.yaml
ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
  dependencies:
    - name: cert-manager
      version: v1.20.0
```

The `name: cert-manager` entry is matched against the existing dependencies list, and only the `version` field is updated. No placeholders needed since this isn't an image override.

## SOP: Onboarding a New Component Repository

### Prerequisites

- The component has a `Dockerfile` that ci-operator can build
- The component is deployable via a Helm chart in this repo (rosa-hyperfleet)

### Step 1: Create quay.io repository

Create a **public** repository under `quay.io/rrp-dev-ci/` for the component. Grant the existing robot account (used by `rosa-hyperfleet-dev-ci-quay-push`) push access.

### Step 2: Add CI config in openshift/release to your repository's job config

Edit `ci-operator/config/<repo>/<org>-<repo>-<branch>.yaml`, e.g. [here](https://github.com/openshift/release/pull/76818/changes#diff-e1f3e71b4382080dfc304ae3b05b7cc97e95f2bf6cf49d744c4901fdc55274e1) for [rosa-hyperfleet-api](https://github.com/openshift-online/rosa-hyperfleet-api):

```yaml
images:
  - dockerfile_path: Dockerfile
    to: <pipeline-image-name>

tests:
  # ... existing tests ...
  - always_run: false
    as: rosa-regionality-compatibility-e2e
    steps:
      dependencies:
        CI_COMPONENT_IMAGE: <pipeline-image-name>
      env:
        ROSA_REGIONAL_COMPONENT_NAME: "<component-name>"
        ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
          <yaml-fragment-with-IMAGE_REPO-and-IMAGE_TAG-placeholders>
        ROSA_REGIONAL_HELM_VALUES_FILE: "argocd/config/regional-cluster/<component-name>/values.yaml"
        ROSA_REGIONAL_QUAY_DEST_REPO: "quay.io/rrp-dev-ci/<component>"
      workflow: rosa-hyperfleet-ephemeral-e2e
```

Where:

- `<pipeline-image-name>` — the `to` field from your `images` section (used as the dependency name)
- `<component-name>` — the component's directory name under `argocd/config/<regional|management>-cluster/` in this repo (e.g., `platform-api`)
- `ROSA_REGIONAL_QUAY_DEST_REPO` — the public quay.io repo from step 1

### Step 3: Regenerate and submit

```bash
cd openshift/release
make update
make checkconfig
# Open PR
```

### Step 4: Trigger

On any PR in the component repo:

```
/test rosa-regionality-compatibility-e2e
```
