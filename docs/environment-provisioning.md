# Provision a New Environment

Set up a central pipeline that provisions Regional and Management Clusters with ArgoCD and Maestro connectivity.

---

## 1. Prerequisites

### Required tools

```bash
aws --version
terraform --version
python --version
jq --version
```

### 1.1 Required AWS accounts

Three accounts are needed:

- **Central** — hosts the CodePipeline infrastructure
- **Regional** — hosts the Regional Infrastructure (including EKS Regional Cluster)
- **Management** — hosts the Management Infrastructure (including EKS Management Cluster)

The Regional and Management accounts must allow assume-role from Central (see 1.2).

### 1.2 Enable assume-role

Add the Central account to the `OrganizationAccountAccessRole` trust policy in both the Regional and Management accounts:

```bash
CENTRAL_ACCOUNT_ID="123456789012"
ROLE_NAME="OrganizationAccountAccessRole"

# Get current trust policy and add Central account
aws iam get-role --role-name $ROLE_NAME --query 'Role.AssumeRolePolicyDocument' --output json | \
  jq --arg account "arn:aws:iam::${CENTRAL_ACCOUNT_ID}:root" \
  '.Statement[0].Principal.AWS |= (if type == "array" then (. + [$account] | unique) else [., $account] | unique end)' \
  > /tmp/trust-policy-updated.json

aws iam update-assume-role-policy \
  --role-name $ROLE_NAME \
  --policy-document file:///tmp/trust-policy-updated.json

# Repeat for the Management account (switch credentials first)
```

## 2. Configure the Region

> **Skip this step** if reusing an existing environment/region configuration.

### 2.1 Store account IDs in SSM

Push the Regional and Management account IDs to SSM Parameter Store in the Central account. The default config uses the resolver URI `ssm:///infra/<environment>/<region>/account_id` to look up account IDs at runtime; the actual SSM parameter name stored in Parameter Store is `/infra/<environment>/<region>/account_id` (the `ssm://` prefix is stripped by the resolver).

```bash
ENV=my-env
REGION=us-east-1
RC_ACCOUNT_ID=123456789012    # Regional Cluster account
MC_ACCOUNT_ID=987654321098    # Management Cluster account

aws ssm put-parameter --name "/infra/${ENV}/${REGION}/account_id" \
  --value "$RC_ACCOUNT_ID" --type String
aws ssm put-parameter --name "/infra/${ENV}/${REGION}/mc01/account_id" \
  --value "$MC_ACCOUNT_ID" --type String
```

### 2.2 Add the environment configuration

Create a new region config file at `config/<environment>/<region>.yaml`. This inherits defaults from `config/defaults.yaml` — override only what differs. Environment-level defaults can be set in `config/<environment>/defaults.yaml`.

```yaml
# config/my-env/us-east-1.yaml
management_clusters:
  mc01: {}
```

To enable the bastion:

```yaml
# config/my-env/us-east-1.yaml
terraform_vars:
  enable_bastion: true
management_clusters:
  mc01: {}
```

### 2.3 Render and commit

```bash
uv run scripts/render.py
ls deploy/<environment>/<region>/    # verify argocd/ and terraform/ dirs exist

git add config/ deploy/
git commit -m "Add <environment>/<region> configuration"
git push origin <your-branch>
```

---

## 3. Bootstrap the Central Pipeline

Switch to your Central AWS profile and create the CodePipelines.

### 3.1 Run the bootstrap script

```bash
export AWS_PROFILE=<central-profile>

GITHUB_REPOSITORY=<org>/rosa-regional-platform \
GITHUB_BRANCH=<branch> \
TARGET_ENVIRONMENT=<environment> \
./scripts/bootstrap-central-account.sh
```

Defaults to `openshift-online/rosa-regional-platform` on `main` if not specified.

### 3.2 Accept the CodeStar connection

The bootstrap script creates a CodeStar connection and polls until it becomes AVAILABLE. While it waits:

1. Open the [AWS CodeStar Connections console](https://console.aws.amazon.com/codesuite/settings/connections) in the Central account
2. Find the **Pending** connection and click **Update pending connection**
3. Click **Install a new app**, then install the GitHub App on the repository you are targeting — this is required for the GitOps pipeline triggers to pick up changes

The script proceeds automatically once the connection is authorized.

## 4. Verification

### 4.1 Connect to the bastion

Requires `enable_bastion: true` in config. Use the respective account's credentials (Regional for the RC bastion, Management for the MC bastion):

```bash
# Connect to the regional cluster bastion (default)
export AWS_PROFILE=<regional-profile>
./scripts/dev/bastion-connect.sh

# Connect to the management cluster bastion
export AWS_PROFILE=<management-profile>
./scripts/dev/bastion-connect.sh management
```

### 4.2 Verify ArgoCD applications

From the Regional Cluster bastion:

```bash
kubectl get applications -A
```

Expected output:

```
NAMESPACE   NAME                  SYNC STATUS   HEALTH STATUS
argocd      argocd                Synced        Healthy
argocd      hyperfleet-adapter1   Synced        Healthy
argocd      hyperfleet-api        Synced        Healthy
argocd      hyperfleet-sentinel   Synced        Healthy
argocd      maestro-server        Synced        Healthy
argocd      monitoring          Synced        Healthy
argocd      platform-api        Synced        Healthy
argocd      root                Synced        Healthy
argocd      storageclass        Synced        Healthy
```

From the Management Cluster bastion:

```bash
kubectl get applications -A
```

Expected output:

```
NAMESPACE   NAME            SYNC STATUS   HEALTH STATUS
argocd      argocd          Synced        Healthy
argocd      cert-manager    Synced        Healthy
argocd      hypershift      Synced        Healthy
argocd      maestro-agent   Synced        Healthy
argocd      monitoring      Synced        Healthy
argocd      root            Synced        Healthy
argocd      storageclass    Synced        Healthy
```

### 4.3 Verify the Platform API

From the Central account, extract the API Gateway endpoint from terraform output:

```bash
export AWS_PROFILE=<central-profile>
cd terraform/config/pipeline-regional-cluster/

terraform init -reconfigure \
  -backend-config="bucket=terraform-state-<CENTRAL_ACCOUNT_ID>" \
  -backend-config="key=regional-cluster/regional-<region>.tfstate" \
  -backend-config="region=<region>"

terraform output -raw api_test_command
# Then run the output command, e.g.:
# awscurl --service execute-api --region us-east-2 https://<id>.execute-api.<region>.amazonaws.com/prod/v0/live
```

> **Note:** The API Gateway accepts requests from any authenticated AWS principal. Authorization is enforced by the Platform API backend — only accounts registered with the Platform API (starting with the bootstrap account) receive a successful response.

### 4.4 Verify Maestro Connectivity

From the Regional account, verify IoT certificates are active:

```bash
export AWS_PROFILE=<regional-profile>

aws iot describe-endpoint --endpoint-type iot:Data-ATS
aws iot list-certificates | jq -r '.certificates[].status'
```

---

## Appendix

### Register additional accounts

The bootstrap account (seeded by Terraform via the `bootstrap_accounts` variable) is the only account authorized to call the Platform API initially. To authorize additional AWS accounts, the first invocation must be made from the bootstrap account:

```bash
awscurl -X POST $API_GATEWAY_URL/api/v0/accounts \
    --service execute-api --region <region> \
    -H "Content-Type: application/json" \
    -d '{"accountId": "<AWS_ACCOUNT_ID>", "privileged": true}'
```

> **Note:** The `API_GATEWAY_URL` can be obtained from `terraform output -raw api_gateway_invoke_url` in the regional cluster terraform config. The `awscurl` request must be signed with credentials from an already-authorized account (initially, the bootstrap account).

### Trigger pipelines via CLI

Pipelines are triggered automatically by Git pushes, but you can also trigger them manually. Requires Central account credentials.

```bash
export AWS_PROFILE=<central-profile>

# List available pipelines
aws codepipeline list-pipelines \
  --query 'pipelines[*].[name,created,updated]' \
  --output table

# Trigger a specific pipeline (fetches latest commit)
aws codepipeline start-pipeline-execution --name rc-pipe-<hash>
```
