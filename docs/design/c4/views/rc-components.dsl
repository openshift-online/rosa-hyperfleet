# =====================================================================
# Component view — zooms into RC specifically. Same "regular user flow"
# scope as the Container view (see views/containers.dsl): MC and
# Customer Hosted Cluster stay as opaque context boxes where they
# relate directly to an RC component; SRE/ZOA, alerting (Slack/
# PagerDuty/SNS), CI (Prow), and Telemeter are out of scope here since
# no single RC component owns those relationships yet. Konflux is
# deliberately hidden too (transitively related via ECR, one hop too
# far for this level of detail), unlike the coarser System Context and
# Container views where it's pulled in explicitly. customerAdmin ->
# rhSso is excluded for the same reason as in views/containers.dsl: a
# customer-side step independent of RC, whose pull away from
# platformApi split Customer Admin from End User in auto-layout.
#
# rc now also has a ZOA component slice (model/containers.dsl) — `sre`
# and all `zoa*`/`kubeApiServer` components are excluded here with
# `include *` pulling them in otherwise; they get their own dedicated
# view instead (views/zoa-components.dsl), same scoping discipline as
# everything else kept out of this one.
# =====================================================================

component seaplane.rc "RCComponents" "Regional Cluster (RC) internals: how a customer's request to create and run a hosted cluster is served." {
    include *
    exclude "customerAdmin -> rhSso"
    exclude sre
    exclude seaplane.rc.zoaAccessLambda
    exclude seaplane.rc.zoaApiLambda
    exclude seaplane.rc.zoaWorkerLambda
    exclude seaplane.rc.zoaBoundary
    exclude seaplane.rc.zoaDataStore
    exclude seaplane.rc.kubeApiServer
    autolayout lr
}
