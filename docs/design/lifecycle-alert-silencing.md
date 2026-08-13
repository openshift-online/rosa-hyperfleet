# Lifecycle alert silencing for HyperFleet

**Last Updated Date**: 2026-08-13

## Summary

Replace PromQL `unless` lifecycle exclusions in regional alert rules with **Alertmanager silences** managed by a **HyperFleet silence reconciler** that reads cluster lifecycle state from **hyperfleet-db** and writes to the **regional cluster (RC) Alertmanager** using the Alertmanager v2 silence API (`POST /api/v2/silences`, `DELETE /api/v2/silence/{silenceID}`).

## Context

- **Problem Statement**: Install/delete suppression is embedded in every SLA alert expression (`unless on(namespace, name, cluster) (hcp:lifecycle_installing or hcp:lifecycle_deleting)` — [hcp-sla.yaml](../../argocd/config/regional-cluster/alerting-rules/templates/hcp-sla.yaml)). Each new alert must remember the wrapper; new reasons (limited support, maintenance) require more recording rules; lifecycle logic lives in metrics instead of the control plane that already owns cluster state.
- **Constraints**: Evaluation and paging run on the RC ([alerting architecture](alerting-architecture.md)); silences must scope per HostedCluster; install-timeout alerts must remain fireable during install ([hcp-installation.yaml](../../argocd/config/regional-cluster/alerting-rules/templates/hcp-installation.yaml)).
- **Assumptions**: Control plane is **hyperfleet-operator** + **hyperfleet-db** ([regional architecture](regional-control-plane-architecture.md)); MVP talks to in-cluster RC Alertmanager over Kubernetes `Service` DNS.

Prior RHOBS direction prefers **Alertmanager silence API + an external lifecycle caller** over PromQL wrappers ([Observatorium silence API #904](https://github.com/observatorium/api/pull/904), [OpenAPI spec](https://github.com/observatorium/api/blob/main/client/spec.yaml)).

## Alternatives Considered

1. **Keep / expand PromQL `unless` wrappers**: Rejected — does not scale as alert and lifecycle-reason cardinality grows.
2. **Embed silence logic in the main hyperfleet-operator reconciler**: Rejected — couples paging policy to the primary reconcile loop; harder to test and operate independently.
3. **Customer-facing silence API**: Out of scope — privileged ops remain mediated via ZOA.

## Design Rationale

- **Justification**: hyperfleet-db already records lifecycle state (`installing`, `deleting`, `limited_support`, …). A dedicated reconciler maps that state to Alertmanager silences so alert rules only express SLO logic.
- **Comparison**: PromQL suppression duplicates state and drifts; API silences are the standard Alertmanager mechanism and align with upstream RHOBS API work.

## Design

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

### Reconciler ownership and sharding

Add a **dedicated silence reconciler** (controller-runtime) that:

1. Watches cluster lifecycle resources from hyperfleet-db using the **same namespace sharding model as hyperfleet-operator** (per-shard namespace scope, not a single controller scanning the full fleet).
2. Derives silence **intent** from cluster state: `installing`, `deleting`, `limited_support`, `maintenance`.
3. Reconciles Alertmanager silences to that intent; persists silence IDs, intent hash, and `endsAt` in hyperfleet-db.

Each silence is keyed by `(cluster_id, lifecycle_reason)` with `createdBy=hyperfleet-silence-reconciler` and a structured comment. Compare desired intent to stored state before calling Alertmanager so the loop is idempotent.

**Orphan detection:** A silence is orphaned when (a) Alertmanager has a silence with our `createdBy` + cluster matchers but hyperfleet-db has no matching active lifecycle intent, or (b) hyperfleet-db has intent but no corresponding silence after reconcile. Startup and periodic reconcile list owned silences, delete (a), and recreate for (b).

### Lifecycle states

| State             | Meaning                                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `installing`      | Cluster provisioning in progress                                                                                               |
| `deleting`        | Cluster teardown in progress                                                                                                   |
| `limited_support` | Cluster marked limited support in platform state                                                                               |
| `maintenance`     | Planned SRE/platform maintenance window on the cluster (operator or platform-api maintenance flag — not customer self-service) |

### Lifecycle behavior

- **Enter silencable state** → `POST /api/v2/silences` with TTL.
- **While state persists** → renew before expiry via `POST /api/v2/silences` with the existing silence `id` and updated `endsAt`.
- **Leave state** → `DELETE /api/v2/silence/{silenceID}`.
- **Ambiguous API responses** → bounded retries; reconcile re-reads persisted IDs before creating duplicates.

Suggested TTLs (each renewal sets `endsAt = now + renewal_window`):

| Reason                    | Initial window   | Renew when remaining  | Renewal window                               |
| ------------------------- | ---------------- | --------------------- | -------------------------------------------- |
| `installing` / `deleting` | 6h               | < 1h                  | 6h                                           |
| `limited_support`         | 24h              | < 4h                  | 24h                                          |
| `maintenance`             | Until window end | < 30m before `endsAt` | Extend to window end, or +4h if no fixed end |

Example for install: cluster enters `installing` at T0 → silence `endsAt = T0 + 6h`. At T0+5h15m (< 1h left) the reconciler POSTs the same `id` with `endsAt = now + 6h`. Repeats until the cluster leaves `installing`, then DELETE.

### Matchers and exemptions

Scope silences on alert identity labels already on SLA rules: `namespace`, `name`, `cluster`.

**MVP exemption:** per-reason negative matcher — e.g. `alertname != HCPInstallTimeout15m` on the `installing` silence only, not a fleet-wide `silence_eligible` label (that would be too coarse if some lifecycle reasons should suppress an alert and others should not).

| Lifecycle state | Silence? | Exemption notes                                                |
| --------------- | -------- | -------------------------------------------------------------- |
| Installing      | Yes      | Exclude install-timeout alert via negative `alertname` matcher |
| Deleting        | Yes      | TBD for delete-stuck alerts                                    |
| Limited support | Yes      | TBD for billing/security criticals                             |
| Maintenance     | Yes      | Per-window policy                                              |
| Available       | No       | —                                                              |

**Label contract:** SLA burn-rate alerts must carry `namespace`, `name`, and `cluster` labels (already true for [hcp-sla.yaml](../../argocd/config/regional-cluster/alerting-rules/templates/hcp-sla.yaml)). New rules are reviewed in the alerting-rules PR process; implementation may add a `promtool`/rule lint check in a follow-up.

### Client abstraction

```go
type SilenceClient interface {
    List(ctx context.Context, matchers ...Matcher) ([]Silence, error)
    Create(ctx context.Context, s PostableSilence) (id string, err error) // create; include id to update/renew
    Expire(ctx context.Context, id string) error                            // DELETE /api/v2/silence/{id}
}
```

MVP implementation uses in-cluster Alertmanager v2 HTTP.

### Migration

1. Ship reconciler; dual-run PromQL `unless` + API silences for one release.
2. Validate in e2e: silence exists while cluster is installing or deleting; silence removed when cluster becomes available. Install-timeout exemption is covered by matcher unit tests (forcing a stalled install in e2e is impractical).
3. Remove `unless` from SLA alert expressions. Keep lifecycle recording rules if dashboards still need them.

## Consequences

### Positive

- Lifecycle suppression decoupled from individual alert expressions
- New lifecycle reasons do not require editing every PromQL rule
- Aligns with RHOBS Alertmanager silence API direction

### Negative

- Additional reconciler to deploy and monitor
- Silence drift possible if reconciler or Alertmanager is unavailable — mitigated by TTL and reconcile loops

## Cross-Cutting Concerns

### Security

- Dedicated reconciler **ServiceAccount** and **NetworkPolicy** restricting Alertmanager API access to reconciler pods only
- No customer-facing silence write path; ZOA mediates privileged operations

### Reliability

- **Resiliency**: TTL-bound silences; orphan cleanup on reconcile; dual-run PromQL during migration
- **Observability**: Metrics for active silences, reconcile errors, and renewals

| Risk                              | Mitigation                                                                 |
| --------------------------------- | -------------------------------------------------------------------------- |
| Silence API unavailable at create | Retries; alerting on Alertmanager issues; dual-run PromQL during migration |
| Orphan silence after crash        | TTL expiry; orphan detection via `createdBy` + DB intent comparison        |
| Exemption misconfiguration        | Matcher unit tests; per-reason negative `alertname` matchers               |
| Alerts missing identity labels    | Label contract on SLA rules; review on alerting-rules changes              |

## Out of scope

- Customer-facing silence API
- SNS / PagerDuty routing changes
- Silencing on MC-local Prometheus
- Classic OSD clusters (ROSA HCP regional only)

## Future: Observatorium / shared RHOBS API

> **Not part of the MVP.**

The MVP uses **Alertmanager inside the regional cluster**. The **Observatorium tenant silence API** only matters if HyperFleet hosts **full RHOBS per region** as a shared service rather than deploying observability components per RC today — a separate decision, not close in maturity.

If that path is taken later: tenant-scoped silence CRUD ([spec](https://github.com/observatorium/api/blob/main/client/spec.yaml), [#904](https://github.com/observatorium/api/pull/904)); gateway enforcer may require DELETE + POST for renew ([enforcer](https://github.com/observatorium/api/blob/main/api/metrics/v1/alertmanager_enforcer.go)); `SilenceClient` absorbs the transport swap.

## References

- [ROSAENG-62370](https://redhat.atlassian.net/browse/ROSAENG-62370) (spike)
- [ROSAENG-62371](https://redhat.atlassian.net/browse/ROSAENG-62371) (implementation)
