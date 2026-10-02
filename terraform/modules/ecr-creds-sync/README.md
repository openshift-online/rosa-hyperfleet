# ecr-creds-sync Module

Creates the IAM role and EKS Pod Identity association for the `ecr-creds-sync`
controller running on a Management Cluster.

The role grants only `ecr:GetAuthorizationToken`, which is required to mint the
Docker registry token used by HostedCluster pull Secrets.

The association targets the `ecr-creds-sync/ecr-creds-sync` ServiceAccount created
by the matching ArgoCD Helm chart.
