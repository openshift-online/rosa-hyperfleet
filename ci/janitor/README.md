# AWS Account Cleanup (Janitor)

The ephemeral tests create AWS resources across multiple accounts. Teardown relies on `terraform destroy`, which can fail and leak resources. To clean up leaked resources, a CloudFormation-based [aws-nuke-cf](https://github.com/openshift-online/aws-nuke-cf) stack is deployed into each AWS account. It runs aws-nuke on a schedule using an in-account IAM role.

## Configuration

`aws-nuke-config.yaml` contains the nuke configuration for all RRP AWS accounts. It defines:

- **Regions** to scan (us-east-1 + global)
- **Account allowlist** (CI and shared-dev accounts)
- **Preservation presets** — resources that must survive cleanup:
  - `globals`: app-sre-infra, Terraform state, default VPCs, CloudTrails, org roles
  - `ci`: CI identity (e2e/ci IAM users and roles), ECR repos, Route53 zones
  - `shared-dev`: shared-dev user and role
  - `central`: CodeStar connection for GitHub
  - `mc`: SSM pull-secret for management clusters
  - `customer`: HCP customer IAM user

## Deploying to an AWS account

1. Clone [aws-nuke-cf](https://github.com/openshift-online/aws-nuke-cf)
2. Deploy the stack, passing this config (daily at 4 AM cron example):

```bash
make deploy CONFIG_URL=https://raw.githubusercontent.com/openshift-online/rosa-hyperfleet/refs/heads/main/ci/janitor/aws-nuke-config.yaml DRY_RUN=false SCHEDULE="cron(0 4 * * ? *)"
```

3. Repeat for each AWS account that needs cleanup.

See the [aws-nuke-cf README](https://github.com/openshift-online/aws-nuke-cf) for full deployment options.

## Modifying preservation rules

Edit `aws-nuke-config.yaml` to add or remove resource filters. Presets are composed per-account in the `accounts` section. After updating the config, re-upload it to each deployed stack:

```bash
make upload-config CONFIG=/path/to/rosa-hyperfleet/ci/janitor/aws-nuke-config.yaml
```
