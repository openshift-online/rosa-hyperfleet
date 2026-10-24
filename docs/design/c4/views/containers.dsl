# =====================================================================
# Container view — regular user flow only. SRE/ZOA, alerting (Slack/
# PagerDuty/SNS), and CI (Prow) are deliberately out of scope here; they
# still relate to `seaplane` as a whole (see model/relationships.dsl)
# and get their own scoped container view later instead of being
# crammed into this one. Konflux is also hidden — transitively related
# via ECR, not a direct neighbour of anything shown at this level.
# ZOA-tagged relationships are excluded by tag (see model/relationships.dsl)
# so the ZOA-flavoured mc<->rc arrows don't leak in alongside the
# "Desire"-tagged kube-applier one.
# customerAdmin -> rhSso is excluded too: it's a customer-side step
# (getting their own RH token) independent of RC's internals — already
# shown at System Context — and its competing pull away from platformApi
# was what split Customer Admin visually apart from End User in
# auto-layout (a `group` boundary alone didn't fix this; the "People"
# group only renders once the view has no competing container boundary).
# =====================================================================

container seaplane "Containers" "How a customer's request to create and run a hosted cluster flows through the region." {
    include seaplane.rc
    include seaplane.mc
    include seaplane.customerHostedCluster
    include endUser
    include customerAdmin
    include rhSso
    include customerIam
    include globalState
    include ecr
    include configRepo
    include route53Public
    exclude "customerAdmin -> rhSso"
    exclude "relationship.tag==ZOA"
    autolayout lr
}
