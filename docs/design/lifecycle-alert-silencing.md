---
Status: Proposed
Owner: HyperFleet
Jira: https://redhat.atlassian.net/browse/ROSAENG-62370
Related: https://redhat.atlassian.net/browse/ROSAENG-62371
---

# Lifecycle alert silencing for HyperFleet

## Summary

Replace PromQL `unless` lifecycle exclusions in regional alert rules with **Alertmanager silences** managed by a **HyperFleet silence reconciler**. The reconciler reads cluster lifecycle state from **hyperfleet-db** and creates, renews, and deletes silences on the **regional cluster (RC) Alertmanager**.

**Recommendation:** Proceed. MVP uses in-cluster Alertmanager v0.28.x (via [kube-prometheus-stack 72.6.2](../../argocd/config/regional-cluster/monitoring/Chart.yaml)) Alertmanager API v2: `POST /api/v2/silences` to create or update (include `id` in `postableSilence` to renew), and `DELETE /api/v2/silence/{silenceID}` to expire. Dual-run with existing PromQL during rollout, then remove `unless` from alert expressions.

Control plane context: **hyperfleet-operator** + **hyperfleet-db** ([regional architecture](regional-control-plane-architecture.md)).

## Problem

Today, install/delete suppression is embedded in every SLA alert expression:

```yaml
unless on(namespace, name, cluster) (hcp:lifecycle_installing or hcp:lifecycle_deleting)
```

([source](../../argocd/config/regional-cluster/alerting-rules/templates/hcp-sla.yaml))

This does not scale: each new alert must remember the wrapper; new reasons (limited support, maintenance) require more recording rules and PromQL edits; and lifecycle logic lives in metrics instead of the control plane that already owns cluster state.

Prior RHOBS discussion (`#wg-rhobs-2x`, Apr 2026) agreed on **Alertmanager silence API + an external lifecycle caller** rather than PromQL wrappers.

## Current architecture

- **Thanos Ruler** on the RC evaluates `PrometheusRule` CRs against federated RC+MC metrics.
- **RC Alertmanager** routes critical alerts to PagerDuty and fans out via SNS.
- Lifecycle suppression is PromQL-only today; limited support on classic OSD uses a brittle OCM-label → metric → PromQL chain we want to avoid for HCP.

See [alerting architecture](alerting-architecture.md).

## Proposed design

### Components

```mermaid
flowchart LR
  subgraph RC["Regional cluster"]
    Reconciler["Silence reconciler"]
    AM["Alertmanager"]
    TR["Thanos Ruler"]
    TR -->|alerts| AM
    Reconciler -->|POST/DELETE silence API| AM
  end
  DB[(hyperfleet-db)] --- Reconciler
  AM --> PD[PagerDuty]
```

**Principle:** PromQL answers whether an SLO is burning; silences answer whether humans should be notified for a given cluster right now.

### Ownership

Add a **dedicated silence reconciler** (not embedded in the main operator loop, not a webhook or cron-only job) that:

1. Derives silence **intent** from hyperfleet-db cluster state (`installing`, `deleting`, `limited_support`, `maintenance`).
2. Reconciles Alertmanager silences to that intent (single leader writer via controller-runtime leader election).
3. Persists silence IDs, intent hash, and `endsAt` in hyperfleet-db for restart recovery.

Each silence is owned by a stable key `(cluster_id, lifecycle_reason)` with `createdBy=hyperfleet-silence-reconciler` and a structured comment. On reconcile, compare desired intent to stored state before calling Alertmanager so the loop is idempotent. Heal drift on startup by listing owned silences and reconciling against current DB intent.

### Lifecycle behavior

- **Enter silencable state** → `POST /api/v2/silences` with TTL.
- **While state persists** → renew before expiry by `POST /api/v2/silences` with the existing silence `id` and updated `endsAt` (native Alertmanager v0.28.x supports update-by-ID via POST).
- **Leave state** → `DELETE /api/v2/silence/{silenceID}`.
- **Controller restart** → list/filter by `createdBy` + matchers or persisted IDs; delete orphans and recreate missing silences.
- **Ambiguous API responses** → bounded retries; reconcile re-reads persisted IDs before creating duplicates.

Suggested TTLs (each renewal sets `endsAt = now + renewal_window`):

| Reason                    | Initial window   | Renew when remaining  | Renewal window                               |
| ------------------------- | ---------------- | --------------------- | -------------------------------------------- |
| `installing` / `deleting` | 6h               | < 1h                  | 6h (same as initial)                         |
| `limited_support`         | 24h              | < 4h                  | 24h                                          |
| `maintenance`             | Until window end | < 30m before `endsAt` | Extend to window end, or +4h if no fixed end |

Example for install: cluster enters `installing` at T0 → silence `endsAt = T0 + 6h`. Reconciler runs periodically; at T0+5h15m (45m left) it POSTs the same silence `id` with `endsAt = now + 6h` (rolls forward). Repeats until the cluster leaves `installing`, then DELETE.

### Matchers and exemptions

Scope silences on existing alert identity labels: `namespace`, `name`, `cluster`.

**MVP exemption:** negative matcher so `HCPInstallTimeout15m` still fires during install ([installation rules](../../argocd/config/regional-cluster/alerting-rules/templates/hcp-installation.yaml)).

Longer-term: label silenceable alerts with `silence_eligible: "true"` and omit on exempt alerts.

| Lifecycle state | Silence? | Notes                              |
| --------------- | -------- | ---------------------------------- |
| Installing      | Yes      | Except install-timeout alert       |
| Deleting        | Yes      | TBD for delete-stuck alerts        |
| Limited support | Yes      | TBD for billing/security criticals |
| Maintenance     | Yes      | Per-window policy                  |
| Available       | No       | —                                  |

### Auth (MVP)

The MVP path is **in-cluster HTTP** to RC Alertmanager (Kubernetes `Service` DNS). It does not traverse AWS APIs, so **AWS IAM is not the auth boundary** for this write path.

Access controls for MVP:

- Dedicated reconciler **ServiceAccount** (no shared operator credentials).
- **NetworkPolicy** allowing only the reconciler pods to reach Alertmanager on the API port.
- **Kubernetes RBAC** if Alertmanager is fronted with auth middleware in future chart versions.
- No customer-facing silence write path; ZOA remains the mediation layer for privileged ops.

AWS SigV4 / OIDC apply only to the future Observatorium gateway path (see below).

### Client abstraction

```go
type SilenceClient interface {
    List(ctx context.Context, matchers ...Matcher) ([]Silence, error)
    Create(ctx context.Context, s PostableSilence) (id string, err error) // create; include id to update/renew
    Expire(ctx context.Context, id string) error                            // DELETE /api/v2/silence/{id}
}
```

MVP implementation talks to in-cluster Alertmanager v2. The interface allows swapping transport later without changing reconciler logic.

### Migration

1. Ship reconciler; dual-run PromQL `unless` + API silences for one release.
2. Validate in e2e: install → silence exists; install-timeout still fires; cluster ready → silence removed.
3. Remove `unless` from SLA alert expressions. Keep lifecycle recording rules if dashboards still need them.

### Key risks

| Risk                              | Mitigation                                             |
| --------------------------------- | ------------------------------------------------------ |
| Silence API unavailable at create | Retry, metrics, dual-run PromQL during migration       |
| Orphan silence after crash        | TTL expiry; heal on startup via list + `createdBy`     |
| Exemption misconfiguration        | Matcher unit tests; deny-list; e2e for install timeout |
| Alerts missing identity labels    | Label contract + CI check                              |

### Out of scope

- Customer-facing silence API
- SNS / PagerDuty routing changes
- Silencing on MC-local Prometheus (evaluation is on RC Thanos Ruler)
- Classic OSD clusters (ROSA HCP regional only)

### Next steps

1. Implement client + reconciler ([ROSAENG-62371](https://redhat.atlassian.net/browse/ROSAENG-62371)).
2. Add limited support / maintenance intents after install/delete soak.

---

## Future: Observatorium / shared RHOBS API

> **Not part of the MVP.** Included for context only.

The MVP deploys and talks to **Alertmanager inside the regional cluster** — the same v2 silence contract HyperFleet already uses for paging ([alerting architecture](alerting-architecture.md)).

We would only need the **Observatorium tenant silence API** if HyperFleet moves from _deploying observability components per RC_ to hosting **RHOBS as a shared regional service** (full RHOBS stack colocated in regional clusters, not just Thanos Ruler + Alertmanager as today). That is a separate platform decision; we are not close to it in maturity or design.

If that path is taken later:

- Observatorium exposes Alertmanager v2 silence CRUD per tenant ([spec](https://github.com/observatorium/api/blob/main/client/spec.yaml), [silence-by-ID PR #904](https://github.com/observatorium/api/pull/904)).
- Paths: `POST/GET /api/metrics/v1/{tenant}/am/api/v2/silences`, `GET/DELETE …/silence/{silenceID}`.
- Tenant enforcer injects tenant matcher, **rejects update-by-ID** on the gateway (renew = delete + recreate — unlike native in-cluster AM), requires ≥1 matcher beyond tenant label ([enforcer](https://github.com/observatorium/api/blob/main/api/metrics/v1/alertmanager_enforcer.go)).
- Auth would follow the shared gateway model (SigV4 / OIDC) rather than in-cluster SA.
- The `SilenceClient` abstraction above is intended to absorb that swap without reconciler changes.

Open questions for that future (not blocking MVP): gateway auth choice, rate limits, audit retention, and whether the same client serves classic OSD.
