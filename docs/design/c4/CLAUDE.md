# C4 Model - Claude Instructions

Context for whoever (human or Claude session) picks up work on the C4 model in this directory.

## Keeping context lean (use agents for read-heavy work)

Work in this directory burns context fast: rendered diagrams (PNG/SVG) and the ADRs in
`docs/design/` are token-heavy, and re-reading them into the main thread is what fills the window.

- **Delegate research, don't inline it.** For "what does ADR _X_ say about _Y_" or "where is _Z_
  defined", spawn the `Explore` agent or a fork and ask for a short written answer. Launch
  independent lookups as parallel agents in one message.
- **Verify diagrams via text, not images.** Reading a rendered PNG costs far more tokens than
  reading the generated `structurizr-*.puml`. To confirm an element, relationship, or label, read
  the `.puml`. Only render and view an actual image when you need to judge visual layout.
- **Batch, then edit.** Do grep/read passes together, draw conclusions, then make the edits.

## Intended deliverable: interactive Structurizr Lite

The goal is to publish this model as a **shared, interactive webpage**, not static PNG/SVG exports.

- **Lite and `make static` both use Structurizr's own server-side Graphviz automatic layout**,
  honoring the DSL's `autoLayout` tuning (direction, rankSeparation, nodeSeparation) directly —
  Graphviz is a documented prerequisite for Lite itself, not just static export. The PlantUML
  export behind `make` / `make png` is a genuinely separate pipeline: it converts the DSL to
  PlantUML text, which the external `plantuml` tool lays out via its *own*, independent Graphviz
  invocation that doesn't read Structurizr's `autoLayout` values at all. That's why PNG/SVG
  positioning can differ from Lite/the published site — judge layout in Lite or `make static`.
- **Hosting**: `structurizr-cli`'s `-format static` export (wired up as `make static`) renders the
  same interactive JS diagram viewer Lite uses (pan/zoom, click-through, tooltips) into plain
  HTML/CSS/JS with the workspace JSON embedded — no backend needed. That folder is what gets
  published (e.g. GitHub Pages); `make lite` stays the *editing* tool. Gap: this export is
  diagrams-only, no documentation/ADR pages — revisit via
  [structurizr-site-generatr](https://github.com/avisi-cloud/structurizr-site-generatr) if wanted.
  See `README.md`'s "Sharing an interactive view" section.

## Compliance driver: FedRAMP 20x Class C

This model is part of the evidence that the ROSA Seaplane regional architecture satisfies
**FedRAMP 20x Class C** ("the new FedRAMP Moderate"; see
https://www.fedramp.gov/2026/reference/key-security-indicators/#change-management). FedRAMP 20x
replaces the old Low/Moderate/High control-catalog model with **Key Security Indicators (KSIs)**.

The **Change Management (KSI-CMT)** group is the one this model most directly demonstrates:

- **KSI-CMT-RMV** ("changes are executed through the redeployment of version-controlled resources
  rather than direct modification wherever reasonable") — `configRepo` exists to prove this: the
  region changes by redeploying from a version-controlled source, never by hand-mutating live
  state. Note ZOA (`zoa-architecture.md`) is a deliberate, fully-audited exception that mutates
  live state directly — don't word GitOps descriptions as "never" direct mutation; match the ADR's
  own "wherever reasonable" hedge.
- **KSI-CMT-VTD** ("persistent testing and validation of changes throughout deployment is
  automated") — `prow -> configRepo` (gates merges) and `prow -> seaplane` (validates which OCP Z/Y
  releases are safe to adopt) model this at System Context. The deeper mechanism (continuous
  fleet-sourced upgrade testing) lives in
  `cluster-upgrades.md` on the **`docs/cluster-upgrades-design` branch** (not yet merged — won't be
  found under `docs/design/` on this branch or other worktrees). None of that mechanism detail
  belongs in this model until a cluster-lifecycle Container/Component view exists.
- **KSI-CMT-LMC** / **KSI-CMT-RVP** — still Container/Component-level concerns not yet modelled.

**Wording convention**: diagram descriptions state architectural facts ("redeploy, don't mutate"),
never raw KSI IDs or control citations — compliance mapping belongs in a dedicated doc, not labels.

## What we're doing

Building a [C4 model](https://c4model.com/) of **ROSA Seaplane** (previously branded "ROSA
HyperFleet" — that name is deprecated, don't reintroduce it), authored as code with the
[Structurizr DSL](https://docs.structurizr.com/dsl).

A first attempt produced a comprehensive model (~60 containers/components, 17 views) that turned
out unreadable — a wall-map, not a usable diagram. It was discarded entirely and rebuilt from a
single **System Context** view, one level at a time. That's still the working method: each
abstraction level should be agreed before the next is built, and each view should earn its own
scope rather than inheriting everything from the level above.

## Modelling discipline — push back on violations, don't just comply

Flag and explain (then offer the correct alternative) rather than silently complying, if asked to:

- Mix abstraction levels in one view (a container/component in a System Context diagram, or a
  container's internals in a Container-level view).
- Show the internals of external/third-party systems — they stay opaque boxes.
- Cram enough elements into one view that it stops being readable on one page — fix with scoped
  slices, not one giant view.
- Jump to Component or Code diagrams before Container (and Container before System Context) exists
  and is agreed on.
- Treat diagrams as source of truth instead of the DSL model — the model is canonical, diagrams are
  generated views of it (see README.md's Rendering section).

## Current state of the model

- `workspace.dsl`: one software system, `seaplane` = "ROSA Seaplane (Region)". Containers nested
  inside it via `!include model/containers.dsl`.
- `model/people-external.dsl`: people (End User, Customer Admin, SRE — End User/Customer Admin
  nested under a `group "Customer"` inside `group "People"`) + external systems (Konflux, Amazon
  ECR, Config Git Repo, Slack, PagerDuty, SNS Alert Subscribers [planned], Customer AWS IAM/STS, Red
  Hat SSO, ROSA Global State, Route 53, Prow, Telemeter [no ADR yet, confirmed verbally], Central
  [ZOA's cross-region SSM discovery registry]).
- `model/containers.dsl`: three containers inside `seaplane`. `rc` (Regional Cluster) is decomposed
  into: `platformApi`, `operator` (Seaplane/HyperFleet Operator), `seaplaneDb` (Postgres),
  `desireTables` (Desire DynamoDB Tables), `argoCdRc`, `alertmanager`, plus a ZOA slice
  (`zoaAccessLambda`/`zoaApiLambda`/`zoaWorkerLambda`/`zoaBoundary`/`zoaDataStore`/`kubeApiServer`).
  `mc` (Management Cluster) is decomposed into: `kubeApplier`, `hyperShiftOperator`, `argoCdMc`,
  plus a ZOA slice of `zoaApiLambda`/`zoaWorkerLambda`/`zoaBoundary`/`kubeApiServer` — no Access
  Lambda or Data Store on MC; those are RC-only and shared cross-account (MC's Lambdas write to
  RC's `zoaDataStore` directly). `customerHostedCluster` stays coarse. Reference components from outside their block via the full hierarchical path (e.g.
  `seaplane.rc.platformApi`) — `!identifiers hierarchical` scopes a short name to the block where
  it's declared.
- `model/relationships.dsl`: relationships point at the specific component that owns them, not the
  whole container/system, wherever that's known. Things deliberately left at a coarser level:
  Terraform-modules reads (provisioning-pipeline concern, not an app component), `route53Public`
  (infra/network-layer), `slack` (unresolved — its real source, the central CodeBuild pipeline,
  isn't modelled). `mc -> rc.desireTables` (never `rc.operator` — see kube-applier gap below) and
  `mc.hyperShiftOperator -> customerHostedCluster` are the two most load-bearing re-points.
  `!impliedRelationships true` (set in `workspace.dsl`) means re-pointing a relationship down to a
  component automatically keeps coarser views' arrows working — but when two distinct child
  relationships would imply the *same* coarser arrow, only one survives (not a bug — the full
  picture is visible at the level where the split exists). If you need both facts visible at a
  coarser level too, add an **explicit, non-implied** relationship there directly (bit us twice:
  once with the Helm/images vs. Terraform-modules split, once when ZOA's `mc -> rc.zoaDataStore`
  relationships silently overwrote the Containers view's kube-applier description).
- **`include *` leakage**: adding components to a container can silently pull them (and their
  relationship partners, e.g. `sre`) into every existing `include *` view scoped to that same
  container. Re-check every such view whenever you add components.
- `views/structure.dsl` (`SystemContext`): `autolayout lr 200 70`. Setting `autolayout` in the DSL
  locks the view against manual dragging in Lite — accepted tradeoff for now (crossing arrows over
  hand-positioning); revisit by removing `autolayout` if wanted later.
- `views/containers.dsl` (`Containers`): regular-user-flow scope only, explicit `include` list.
  SRE/ZOA and alerting/CI excluded on purpose, pending separate scoped views (now built — see ZOA
  views below; alerting still pending).
- `views/rc-components.dsl` / `views/mc-components.dsl`: Component-level views for RC/MC, `include
  *`, each excluding the other's ZOA slice and `sre` (kube-applier/HyperShift's `kubeApiServer`
  stays included on MC's view — it's shared with the regular flow, not ZOA-exclusive).
  `exclude "customerAdmin -> rhSso"` in both — see the auto-layout lesson below.
- `views/zoa-containers.dsl` / `views/zoa-components.dsl`: SRE/ZOA-scoped views. Break-glass and the
  disabled manual-approval Trusted Action workflow are deliberately not modelled (not real yet).
- `views/styles.dsl`: `Container`, `Serverless`, `EKS`, `Database` tags are live; `Component`, `AWS`,
  `CI` still unused. `Planned`/`Experimental` are lifecycle tags for design-vs-code mismatches.
- `Makefile`: containerized rendering (podman by default). PlantUML+Graphviz over Mermaid because
  Mermaid's auto-layout produces an unreadable hairball at this model's size.
- Generated artifacts (`structurizr-*.svg/png/puml`, `.structurizr/`, `workspace.json`) are
  gitignored — never commit them, they're reproducible from the DSL with `make`.
- See `README.md` for file layout and the full rendering command reference.

## Auto-layout lesson: a drawn-apart pair is usually a relationship-count mismatch, not a grouping bug

When two elements that intuitively "belong together" end up far apart in Lite's auto-layout, the
instinctive diagnosis is "the `group` boundary isn't rendering." That might also be true, but
**it's not why they're far apart** — drawing a box around two elements doesn't move them. The
actual cause is almost always a **relationship-count mismatch**: auto-layout positions same-rank
nodes by the average pull of their connections (barycenter-style), so an element with an extra
relationship to something positioned elsewhere gets dragged away from its "sibling" that doesn't
have that extra pull.

Confirmed case: `customerAdmin` had a second relationship (`-> rhSso`) that `endUser` didn't, which
pulled it toward Red Hat SSO's position. Fix: `exclude "customerAdmin -> rhSso"` in the views where
it doesn't belong anyway (quotes required around a `source -> destination` exclude expression) —
both elements stay visible via their other relationships, only the lopsided pull goes away.

**Diagnostic order**: 1) check for a relationship-count/target-position mismatch first — usually
fixable by excluding or re-scoping one relationship; 2) only reach for `group` once elements are
*already* roughly adjacent. Confirmed empirically: `group` reliably renders only in views where the
system in focus is a flat box (System Context) — once a view expands the system into its own
boundary (Container/Component views), the group boundary doesn't render alongside it, in both the
PlantUML export and Lite itself. The alternate `plantuml/c4plantuml` export style has no `group`
concept at all (only `System_Boundary`), so that's not a workaround either.

## Data sources for building containers/components back up

The authoritative source for _what exists_ is the ADRs in `docs/design/*.md`, not memory or
assumption. Read the relevant ADR before modelling a slice:

| Topic                                | ADR(s)                                                                                                                                                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Customer API, control plane, state    | `regional-control-plane-architecture.md`, `rate-limiting-architecture.md`                                                                                                                                 |
| Image build, provisioning, GitOps     | `pipeline-based-lifecycle.md`, `fully-private-eks-bootstrap.md`, `gitops-cluster-configuration.md`, `codebuild-optimization.md`                                                                           |
| Desire distribution (operator -> MC)  | `kube-applier-architecture.md`                                                                                                                                                                            |
| Observability                         | `monitoring-platform.md`, `thanos-metrics-infrastructure.md`, `logging-platform.md`, `alerting-architecture.md`, `infrastructure-logging.md`, `mc-metrics-remote-write.md`, `lifecycle-alert-silencing.md` |
| Networking and identity               | `dns-architecture.md`, `regional-oidc-ownership.md`, `aws-iam-hosted-cluster-authentication.md`                                                                                                           |
| Zero Operator Access (ZOA)            | `zoa-architecture.md`, `sre-ui-access.md`                                                                                                                                                                 |
| Account provisioning                  | `regional-account-minting.md`                                                                                                                                                                             |
| Node/compute                          | `karpenter-node-provisioning.md`, `fips-eks-compute.md`                                                                                                                                                   |

Also useful: the top-level `/Users/jmelisba/work/git/rosa-seaplane-c4-model/CLAUDE.md` (requires the
**architect agent** to review changes under `docs/design/`), and `docs/README.md` / `docs/FAQ.md`.

**When an ADR is ambiguous or disputed, check the actual code** in the sibling repo
`/Users/jmelisba/work/git/rosa-seaplane-api` (RC's Platform API/Operator/DB — still named
`hyperfleet-operator`/`hyperfleet-db` internally) rather than guessing from prose. This resolved a
real kube-applier-placement dispute once (see below). For in-progress/unmerged ADRs on a feature
branch not checked out locally, read via `git show <remote>/<branch>:<path>` rather than checking
out (avoids disturbing the working tree, and the local branch of the same name may have diverged
from the fork, as happened with `rosa-seaplane-zoa`'s `feat/zoa-boundary`).

## Resolved modelling decisions worth knowing before re-deriving them

- **No direct RC<->MC network path, at any level of zoom** — confirmed across
  `kube-applier-architecture.md`, `monitoring-platform.md`, `logging-platform.md`, and
  `mc-metrics-remote-write.md`: every MC<->RC exchange is MC-initiated, never the reverse. Modelled
  as `mc -> rc` (Container level) / `mc -> rc.desireTables` (Component level). Transport-level
  detail for metrics/logs (two API Gateways — one for the Platform API, one for "RHOBS") stays
  deferred to a future network/observability view.
- **No Tekton anywhere in this project.** `codebuild-optimization.md` confirms AWS CodeBuild (one
  project per cluster) is the only provisioning engine. The top-level CLAUDE.md's Tekton mention is
  stale.
- **ZOA Trusted Actions target the Kubernetes API server directly** (an impersonated, ephemeral
  ServiceAccount with scoped RBAC), not `ArgoCD (RC)` as an earlier discarded model assumed.
  Modelled as `kubeApiServer` on both `rc` and `mc`. Grounded in the in-progress "ZOA Boundary"
  feature branch (`rosa-seaplane-zoa` and `rosa-seaplane`, `slopezz/feat/zoa-boundary`, not yet
  merged), which also surfaced the **Central** account (SSM-only discovery registry) and the
  **Boundary** ECS Fargate jump-container (one per RC/MC VPC, SRE connects via SSM before running
  any Trusted Action).
- **Docs vs. code naming still doesn't agree.** `rosa-seaplane-api` uses `hyperfleet-operator`/
  `hyperfleet-db` internally, and a separate repo (`rosa-hyperfleet-kube-applier`) holds the actual
  kube-applier implementation. This model uses the current "Seaplane" names per the
  don't-reintroduce-HyperFleet rule regardless of what the code calls things.
- **kube-applier runs only on MC**, confirmed at the code level, not just the ADR
  (`kube-applier-architecture.md` lines 68, 241-242, and the Go source). RC's side is the
  Seaplane/HyperFleet Operator (writes desires, reads status) plus the Desire DynamoDB tables —
  there is no separate kube-applier process on RC. Easy mistake to re-make: RC's
  `internal/dynamo/client.go` imports a shared library from the `rosa-hyperfleet-kube-applier` repo
  purely for DynamoDB schema compatibility — that import is not evidence of kube-applier running on
  RC. `mc -> rc.desireTables` is the one relationship between them; never point it at `operator`.
- **PagerDuty and SNS share one real component (Alertmanager)**; Slack doesn't, despite looking
  similar at System Context — Slack's only real wiring is CodeBuild pipeline-failure notifications
  via EventBridge, unrelated to Alertmanager. Confirmed via `alerting-architecture.md`.

## Branch / remote state

This work lives on branch `docs/c4-model`, rebased onto `origin/main`
(`git@github.com:openshift-online/rosa-seaplane.git`) and pushed to the `jmelis` remote
(`git@github.com:jmelis/rosa-hyperfleet.git`, a personal fork — not yet opened as a PR against
`origin`). Push follow-up commits to `jmelis`, not `origin`, unless told otherwise.
