styles {

    # ---- Base element shapes ----
    element "Element" {
        color #ffffff
        stroke #333333
        strokeWidth 2
    }
    element "Person" {
        shape Person
        background #4b2e83
        color #ffffff
    }
    element "Software System" {
        background #6c3fa6
        color #ffffff
    }
    element "Container" {
        background #8155b5
        color #ffffff
    }
    element "Component" {
        background #a98bd1
        color #ffffff
    }

    # ---- Semantic tags (applied after the base shapes) ----
    element "External" {
        background #6b6f76
        color #ffffff
    }
    element "Database" {
        shape Cylinder
        background #2d6a4f
        color #ffffff
    }
    element "AWS" {
        background #d86613
        color #ffffff
    }
    element "CI" {
        background #c05621
        color #ffffff
    }
    element "Serverless" {
        shape RoundedBox
        background #e8871a
        color #ffffff
    }
    element "EKS" {
        background #1a73c2
        color #ffffff
    }

    # ---- Lifecycle tags (borders win: declared last) ----
    element "Planned" {
        border Dashed
        opacity 55
        color #ffffff
    }
    element "Experimental" {
        border Dotted
        background #b7791f
        color #ffffff
    }

    # ---- Deployment scaffolding ----
    element "Deployment Node" {
        background #ffffff
        color #333333
        stroke #999999
    }
    element "Infrastructure Node" {
        background #eef1f5
        color #333333
    }

    # ---- Relationships ----
    relationship "Relationship" {
        color #555555
        thickness 2
        fontSize 22
    }
}
