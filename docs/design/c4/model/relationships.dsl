# System Context relationships. Container- and component-level relationships
# move into this file as the model grows past a single software system.

# Explicit, tagged container-level RC<->MC arrows, declared first so
# !impliedRelationships's default strategy doesn't create untagged implied
# duplicates from the cross-container component relationships below (which
# would otherwise leak into views that exclude by tag, e.g. the ZOA arrows
# showing up in the regular-user-flow Containers view).
seaplane.mc -> seaplane.rc "Polls desired cluster and add-on configuration from, and reports status back to" "via kube-applier's shared DynamoDB tables" "Desire"
seaplane.rc -> seaplane.mc "Launches (cross-account) and vends scoped ECS Exec credentials for the ZOA Boundary in" "ecs:RunTask via STS AssumeRole" "ZOA"
seaplane.mc -> seaplane.rc "Records ZOA executions, audit, and session reconciliation in" "cross-account, resource-based policy" "ZOA"

customerAdmin -> seaplane.rc.platformApi "Links AWS account and manages authz policies via" "rosactl / RH token"
customerAdmin -> rhSso "Obtains Red Hat token from"
endUser -> seaplane.rc.platformApi "Creates and manages hosted clusters via" "HTTPS / AWS SigV4"
sre -> central "Looks up the regional Access endpoint for a deployment via" "SSM (pre-flight discovery, before any regional call)"
seaplane.rc -> central "Publishes its Access endpoint and invoker role for discovery via" "Terraform-managed SSM parameter"
sre -> seaplane.rc.zoaAccessLambda "Starts, lists, joins, and terminates audited boundary sessions via" "HTTPS / AWS SigV4 (Function URL, IAM auth)"
sre -> seaplane.rc.zoaBoundary "Connects to the audited interactive shell via" "ECS Exec / SSM Session Manager"
sre -> seaplane.mc.zoaBoundary "Connects to the audited interactive shell via" "ECS Exec / SSM Session Manager"
seaplane.rc.zoaAccessLambda -> seaplane.mc.zoaBoundary "Launches (cross-account) and vends scoped ECS Exec credentials for" "ecs:RunTask via STS AssumeRole"
seaplane.mc.zoaApiLambda -> seaplane.rc.zoaDataStore "Records execution and audit entries in, uploads Trusted Action output/logs to" "cross-account, resource-based policy"
seaplane.mc.zoaWorkerLambda -> seaplane.rc.zoaDataStore "Reconciles async executions, runs garbage collection, and reaps idle/expired boundary sessions in" "cross-account, resource-based policy"

seaplane.rc.argoCdRc -> ecr "Pulls pinned platform and component images from"
seaplane.mc.argoCdMc -> ecr "Pulls pinned platform and component images from"
seaplane.rc.argoCdRc -> configRepo "Reads pinned image SHAs and Helm charts from"
seaplane.rc -> configRepo "Reads Terraform modules from" "Applied by the provisioning pipeline, not an RC-internal component"
seaplane.mc.argoCdMc -> configRepo "Reads pinned image SHAs and Helm charts from"
seaplane.mc -> configRepo "Reads Terraform modules from" "Applied by the provisioning pipeline, not an MC-internal component"
seaplane.rc.platformApi -> rhSso "Validates Red Hat token during account bootstrap"
seaplane.rc.platformApi -> globalState "Reads and writes global identity, policy and attachment state in"
seaplane -> slack "Sends pipeline failure notifications to"
seaplane.rc.alertmanager -> pagerDuty "Pages on-call via (feature-flagged)"
seaplane.rc.alertmanager -> snsSubscribers "Publishes regional alerts to" "" "Planned"
customerIam -> seaplane.rc.platformApi "Issues SigV4 credentials used to authenticate requests to"
route53Public -> seaplane.rc "Delegates regional DNS zones to"
seaplane.rc -> telemeter "Forwards fleet-wide metrics to"

seaplane.mc.kubeApplier -> seaplane.rc.desireTables "Polls desired cluster and add-on configuration from, and reports status back to"
seaplane.mc.hyperShiftOperator -> seaplane.customerHostedCluster "Creates and manages the lifecycle of the hosted control plane for"
seaplane.customerHostedCluster -> seaplane.mc "Worker nodes (in the customer's own AWS account) connect to the hosted control plane's API in"

konflux -> ecr "Builds and mirrors component images into"
prow -> configRepo "Gates merges — blocks bad changes before they reach the deployment pipeline"
prow -> seaplane "Runs e2e and upgrade test suites against — validates which OCP Z/Y releases are safe for the fleet to adopt, protecting the platform from bad payloads and underpinning reliability"
