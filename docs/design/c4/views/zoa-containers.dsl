# =====================================================================
# Container view — ZOA (Zero Operator Access) scope. Mirrors the
# regular-user-flow Container view (views/containers.dsl), but for
# SRE's audited operational-access path instead of the customer-facing
# one. Deliberately coarse: rc and mc stay as single boxes here too;
# the ZOA-specific pieces inside them (Access/API/Worker Lambdas, the
# Boundary ECS task, the shared data store, the Kubernetes API server
# Trusted Actions target) get their own Component-level view next.
#
# Break-glass is not modelled — still an unimplemented stub upstream.
# The manual-approval Trusted Action workflow is implemented in code
# but disabled in product today, so it's left out too, consistent with
# how this model treats other not-yet-real capabilities.
# =====================================================================

container seaplane "ZOA" "How an SRE's audited operational action reaches RC or MC." {
    include seaplane.rc
    include seaplane.mc
    include sre
    include central
    exclude "relationship.tag==Desire"
    autolayout lr
}
