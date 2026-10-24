# People -----------------------------------------------------------------
group "People" {
    group "Customer" {
        endUser       = person "End User" "ROSA customer creating and managing hosted clusters via AWS IAM credentials."
        customerAdmin = person "Customer Admin" "Red Hat org admin who bootstraps the AWS account, links IAM principals, and manages ROSA authz policies."
    }
    sre = person "SRE / Operator" "Red Hat SRE running audited, time-boxed operational actions."
}

# External systems -------------------------------------------------------
ecr            = softwareSystem "Amazon ECR (platform images)" "Central/shared registry the region pulls pinned platform and component images from; fed by Konflux and by automation that mirrors the OCP payloads." "External"
configRepo     = softwareSystem "Config Git Repo" "openshift-online/rosa-seaplane: version-controlled source of truth for pinned image SHAs, Helm charts, and Terraform modules — the region is changed by redeploying from here (GitOps) rather than mutating live state directly, wherever reasonable." "External"
slack          = softwareSystem "Slack" "Receives CodeBuild pipeline FAILED notifications." "External"
pagerDuty      = softwareSystem "PagerDuty" "Incident paging; receives critical alerts from Alertmanager (feature-flagged)." "External"
snsSubscribers = softwareSystem "SNS Alert Subscribers" "Team-owned downstream consumers subscribed to the regional alerts SNS topic for automated remediation (AI)." "External,Planned"
customerIam    = softwareSystem "Customer AWS IAM / STS" "Customer-owned AWS account; source of SigV4 credentials and sts:GetCallerIdentity for hosted-cluster auth." "External"
rhSso          = softwareSystem "Red Hat SSO" "Red Hat identity provider; issues the Red Hat tokens validated when a customer AWS account is bootstrapped (linked)." "External"
globalState    = softwareSystem "ROSA Global State" "Cross-region source of truth for account-to-org links, principal links, and global ROSA policies and attachments (DynamoDB Global Tables)." "External"
route53Public  = softwareSystem "Route 53 public DNS / Cloudflare" "openshiftapps.com root zone delegating to the regional Route 53 zones." "External"
prow           = softwareSystem "Prow (OpenShift CI)" "Runs lint/unit/integration/e2e suites on PRs and nightly schedules; a required merge gate on the Config Git Repo alongside Konflux." "External"
konflux        = softwareSystem "Konflux" "Builds and mirrors component container images into the platform ECR." "External"
telemeter      = softwareSystem "Telemeter" "Red Hat's centralized fleet-telemetry platform; receives aggregated cluster metrics shipped from the region." "External"
central        = softwareSystem "ZOA Deployment Registry (Central)" "Shared, cross-region account holding only SSM discovery pointers (regional ZOA Access endpoint + invoker role per deployment) — no compute, no session state; every region's RC publishes its own entry." "External"
