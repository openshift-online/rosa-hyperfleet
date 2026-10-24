# =====================================================================
# Component view — ZOA (Zero Operator Access) internals, zooming past
# the Container-level ZOA view (views/zoa-containers.dsl). Shows RC's
# and MC's ZOA components side by side to make the symmetric topology
# visible — neither container is otherwise decomposed in this view
# beyond its ZOA slice (see model/containers.dsl).
# =====================================================================

component seaplane.rc "ZOAComponents" "ZOA internals: how an SRE's audited Trusted Action reaches RC or MC's Kubernetes API." {
    include sre
    include central
    include seaplane.rc.zoaAccessLambda
    include seaplane.rc.zoaApiLambda
    include seaplane.rc.zoaWorkerLambda
    include seaplane.rc.zoaBoundary
    include seaplane.rc.zoaDataStore
    include seaplane.rc.kubeApiServer
    include seaplane.mc.zoaApiLambda
    include seaplane.mc.zoaWorkerLambda
    include seaplane.mc.zoaBoundary
    include seaplane.mc.kubeApiServer
    autolayout lr
}
