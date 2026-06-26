---
name: add-pre-merge
description: Generate the openshift/release CI config to onboard a component repository for cross-component pre-merge e2e testing against an ephemeral environment. Use when a user wants to add pre-merge testing, cross-component e2e, or regionality compatibility tests to a component repo.
argument-hint: "[component-name]"
---

You are helping the user onboard a new component repository for cross-component pre-merge e2e testing. Follow the SOP in `docs/adding-component-pre-merge.md`.

## Inputs to gather

If not provided via `$ARGUMENTS`, ask the user for:

1. **Component name** — the directory name under `argocd/config/regional-cluster/` or `argocd/config/management-cluster/` in this repo (e.g., `platform-api`, `maestro-server`). Validate it exists.
2. **Org and repo** — the GitHub org/repo for the component (e.g., `openshift-online/rosa-hyperfleet-api`). This determines the CI config path in openshift/release.
3. **Branch** — the branch to configure (default: `main`).
4. **Dockerfile path** — path to the Dockerfile in the component repo (default: `Dockerfile`).
5. **Pipeline image name** — the `to` field for the built image in ci-operator (default: component name with hyphens, e.g., `platform-api`).
6. **Quay.io repo name** — the public repo under `quay.io/rrp-dev-ci/` (default: same as pipeline image name).

## Determine the override YAML

Read the component's Helm values file at `argocd/config/<regional-cluster|management-cluster>/<component-name>/values.yaml` (or `Chart.yaml` for chart version overrides) to determine the image structure.

Look for the image repository/tag pattern. Common patterns:

```yaml
# Pattern 1: nested under component key
componentName:
  app:
    image:
      repository: quay.io/...
      tag: latest

# Pattern 2: flat
image:
  repository: quay.io/...
  tag: latest
```

Build the `ROSA_REGIONAL_HELM_OVERRIDE_YAML` by mirroring the YAML path to the image repository and tag fields, using `IMAGE_REPO` and `IMAGE_TAG` as placeholders.

## Generate the CI config snippet

Generate a YAML snippet for `ci-operator/config/<org>/<org>-<repo>-<branch>.yaml` in `openshift/release`:

```yaml
images:
  - dockerfile_path: <dockerfile-path>
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
          <generated-override-yaml>
        ROSA_REGIONAL_HELM_VALUES_FILE: "argocd/config/<cluster-type>/<component-name>/values.yaml"
        ROSA_REGIONAL_QUAY_DEST_REPO: "quay.io/rrp-dev-ci/<quay-repo-name>"
      workflow: rosa-hyperfleet-ephemeral-e2e
```

## Output

Present the user with:

1. The generated CI config YAML snippet, ready to paste into their openshift/release config.
2. A checklist of the remaining manual steps:
   - [ ] Create public quay.io repo at `quay.io/rrp-dev-ci/<name>` and grant the robot account push access
   - [ ] Add the snippet to `ci-operator/config/<org>/<org>-<repo>-<branch>.yaml` in openshift/release (note: merge with existing `images` and `tests` sections if they exist)
   - [ ] Run `make update && make checkconfig` in the openshift/release repo
   - [ ] Open PR in openshift/release
   - [ ] Once merged, trigger with `/test rosa-regionality-compatibility-e2e` on any PR in the component repo

Do NOT attempt to clone or modify the openshift/release repo — just generate the config for the user to apply.
