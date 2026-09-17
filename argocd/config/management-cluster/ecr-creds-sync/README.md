# ecr-creds-sync

Deploys the ECR credentials synchronizer to each Management Cluster. The chart
is discovered automatically by the management-cluster ArgoCD ApplicationSet.

## Configuration

All controller settings are under `ecrCredsSync` in `values.yaml`:

- `image`: registry, repository, tag, and pull policy. The default image is
  `quay.io/psav/ecr-creds-sync:latest`.
- `config.ecrRepository`: ECR repository URI containing HostedCluster release
  images.
- `config.awsRegion`: optional AWS region override. Empty uses
  `global.aws_region` injected by the ApplicationSet.
- `config.awsEndpointUrl`: optional AWS endpoint override for emulators such as
  LocalStack.
- `config.refreshAfter`: duration between token refreshes. The default is `2h`.
- The controller serves `/healthz` and `/readyz` on port `8081`; the deployment
  uses these endpoints for liveness and readiness probes.
- `deployment`: replica and resource settings.

The ServiceAccount, ClusterRole, and ClusterRoleBinding are created in the
chart's release namespace. The matching Terraform `ecr-creds-sync` module
associates that ServiceAccount with an IAM role allowing only
`ecr:GetAuthorizationToken`.
