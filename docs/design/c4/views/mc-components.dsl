# =====================================================================
# Component view — zooms into MC specifically, mirroring
# views/rc-components.dsl. Same "regular user flow" scope: Customer
# Hosted Cluster and RC stay as opaque context boxes where they relate
# directly to an MC component. Karpenter and a per-HostedCluster
# Control-Plane-Operator are deliberately not modelled: Karpenter
# deploys identically to RC and MC (generic node-provisioning
# infrastructure, not MC-distinguishing), and the CPO is a dynamically
# instantiated per-customer process, not a standing component — the
# same reasoning that already keeps kube-applier's per-resource
# reconciles and RC's Postgres-level detail out of these diagrams.
#
# MC also has a ZOA Lambda/Boundary slice (model/containers.dsl) — `sre`
# and the `zoa*` components are excluded here with `include *` pulling
# them in otherwise; they get their own dedicated view instead
# (views/zoa-components.dsl), same scoping discipline as
# views/rc-components.dsl. `kubeApiServer` stays IN this view (unlike
# the other zoa* components): it's shared, not ZOA-exclusive —
# kube-applier and HyperShift Operator both target it too.
# =====================================================================

component seaplane.mc "MCComponents" "Management Cluster (MC) internals: how a customer's hosted cluster control plane is run." {
    include *
    exclude sre
    exclude seaplane.mc.zoaApiLambda
    exclude seaplane.mc.zoaWorkerLambda
    exclude seaplane.mc.zoaBoundary
    autolayout lr
}
