# =====================================================================
# System Context view (starting point - container/component views are
# added back in as the model grows past a single software system).
# =====================================================================

systemContext seaplane "SystemContext" "People and external systems around ROSA Seaplane." {
    include *
    # konflux is transitively related (konflux -> ecr -> seaplane), not a direct neighbour of seaplane, so pull it in explicitly
    include konflux
    autolayout lr 200 70
}
