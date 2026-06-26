# Provision a Hosted Cluster

This guide walks through creating a ROSA HCP cluster on the integration environment using the `rosactl` CLI.

## Prerequisites

### ROSA Regional Platform CLI

```bash
git clone https://github.com/openshift-online/rosa-hyperfleet-cli.git
cd rosa-hyperfleet-cli
make build

# Install globally (optional)
make install
```

### Dependencies

```bash
command -v jq >/dev/null || echo "Need jq installed"
```

### Account Allowlisting

Your AWS account must be registered with the platform before you can create clusters. Ask `@rrp-team-ic` in `#team-rosa-hyperfleet` to allowlist your account — provide your **AWS account ID** and the target **environment** (e.g. integration). This is a one-time step per account per environment.

<details>
<summary>IC reference: allowlisting command</summary>

Run from a platform API shell (`make int-shell` or `make ephemeral-shell`):

```bash
awscurl --service execute-api --region "$REGION" \
  -X POST "$API_URL/api/v0/accounts" \
  -H "Content-Type: application/json" \
  -d '{"accountId": "<account-id>", "privileged": true}'
```

</details>

## Set Up

```bash
# Verify you are using the correct AWS account — this is where worker nodes
# will be created. You can use a profile, environment variables, etc.
aws sts get-caller-identity

# Platform API URL (integration environment)
API_URL=https://api.us-east-1.int0.rosa.devshift.net

# Cluster variables
REGION=us-east-1
AZ=${REGION}a
CLUSTER_NAME=<pick-a-name>
```

## Create a Cluster

```bash
# Log in to the platform API
rosactl login --url $API_URL

# 1. Create IAM roles in your account (CloudFormation stack)
rosactl cluster-iam create $CLUSTER_NAME --region $REGION

# 2. Create a VPC for the hosted cluster (CloudFormation stack)
rosactl cluster-vpc create $CLUSTER_NAME --region $REGION --availability-zones $AZ

# 3. Submit the cluster creation request
rosactl cluster create $CLUSTER_NAME --region $REGION

# 4. Get the cluster ID and cloud URL
CLOUDURL=$(rosactl cluster list --region $REGION -o json | jq -r --arg name "$CLUSTER_NAME" '.items[] | select(.name == $name) | "\(.spec.cloudUrl)/\(.id)"')

# 5. Create the OIDC provider (CloudFormation stack)
rosactl cluster-oidc create $CLUSTER_NAME --region $REGION --oidc-issuer-url $CLOUDURL
```

You can then view the status of your cluster as follows:

```bash
watch -n 1 rosactl cluster list $CLUSTER_NAME
```

## Access the Cluster

Once the cluster is ready, generate a kubeconfig:

```bash
rosactl cluster kubeconfig $CLUSTER_NAME --region $REGION > ~/.kube/$CLUSTER_NAME
export KUBECONFIG=~/.kube/$CLUSTER_NAME

# DNS propagation and certificate issuance may take a few minutes after
# cluster creation. Retry if the connection is initially refused.
kubectl get nodes
```

The generated kubeconfig uses `rosactl` as a credential plugin, which signs requests with your active AWS credentials. Make sure the same credentials you used during cluster creation are active.

## Cluster Lifecycle

**Automatic cleanup:** Clusters are automatically deleted after **24 hours** by a platform cleanup job. You do not need to delete them manually.

**CloudFormation stacks persist:** The three CloudFormation stacks in your AWS account (`cluster-iam`, `cluster-vpc`, `cluster-oidc`) are **not** deleted by the cleanup job. You can reuse them when creating your next cluster with the same name, skipping the `cluster-iam`, `cluster-vpc`, and `cluster-oidc` create steps.

## Notes

- If you create more than 5 hosted clusters, ensure your AWS account has sufficient NAT gateway quota (default limit is 5).
- For ephemeral (dev) environments, see [Development Environment](development-environment.md). The cluster creation flow is the same — only the `API_URL` differs.
- For admin teardown procedures, see [Hosted Cluster Teardown](hostedcluster-teardown.md).
- For assistance, reach out to @rrp-team-ic in #team-rosa-hyperfleet.
