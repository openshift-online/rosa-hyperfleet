workspace "ROSA Seaplane" "C4 model of a single ROSA Seaplane region, starting at System Context." {

    !identifiers hierarchical
    !impliedRelationships true

    model {

        properties {
            "structurizr.groupSeparator" "/"
        }

        # People and external systems live outside the system boundary.
        !include model/people-external.dsl

        # The system in focus. Containers (RC/MC/Customer Hosted Cluster)
        # are kept coarse-grained for now; internal services get their own
        # Container/Component views later, scoped separately.
        seaplane = softwareSystem "ROSA Seaplane (Region)" "Regionally-independent fleet management for ROSA HCP in one AWS region." {
            !include model/containers.dsl
        }

        # All relationships in one place; grows to container/component level
        # alongside the model.
        !include model/relationships.dsl
    }

    views {
        !include views/structure.dsl
        !include views/containers.dsl
        !include views/rc-components.dsl
        !include views/mc-components.dsl
        !include views/zoa-containers.dsl
        !include views/zoa-components.dsl
        !include views/styles.dsl
    }
}
