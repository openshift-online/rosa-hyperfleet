# Provision a Hosted Cluster

This guide walks through creating a ROSA HCP cluster on the integration environment using the `rosactl` CLI.

## Prerequisites

### ROSA HyperFleet CLI

```bash
git clone https://github.com/openshift-online/rosa-hyperfleet-cli.git
cd rosa-hyperfleet-cli
make build

# Install globally (optional)
make install
```

### ROSA CLI

```bash
git clone https://github.com/openshift/rosa.git
cd rosa
git checkout hyperfleet-v2
make rosa
# Install into $GOBIN
make install
```

### Dependencies

```bash
command -v jq >/dev/null || echo "Need jq installed"
```

## Set Up

```bash
# Verify you are using the correct AWS account — this is where worker nodes
# will be created. You can use a profile, environment variables, etc.
aws sts get-caller-identity

# Platform API URL
# - Integration: https://api.us-east-1.int0.rosa.devshift.net
# - Stage:       https://api.us-east-1.stg0.rosa.devshift.org
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

# 4. Get the OIDC issuer URL
OIDC_URL=$(rosactl cluster list -o json | jq -r --arg name "$CLUSTER_NAME" '.items[] | select(.name == $name) | .spec.hostedCluster.issuerURL')

# 5. Create the OIDC provider (CloudFormation stack)
rosactl cluster-oidc create $CLUSTER_NAME --oidc-issuer-url $OIDC_URL
```

You can then view the status of your cluster as follows:

```bash
watch -n 1 rosactl cluster list $CLUSTER_NAME
```

## Create a Cluster using ROSA CLI

```bash
# asusuming your running from the ROSA repo folder
✗ ./rosa login --hyperfleet-url $API_URL
I: Logged in to Platform API: https://5abcsz88t2.execute-api.us-east-1.amazonaws.com/prod

✗ ./rosa whoami
AWS ARN:                      arn:aws:iam::754XXXXX
AWS Account ID:               754XXXXX
AWS Default Region:           us-east-1
V2 API:                       https://5abcsz88t2.execute-api.us-east-1.amazonaws.com/prod

✗ ./rosa list clusters
I: No clusters available

✗ ./rosa create oidc-config --managed --mode auto

✗ ./rosa list oidc-config
ID                                    TYPE     ISSUER URL                                                                  SECRET ARN
ef477f3f-0c62-4c6f-9ede-4cbe640e2887  managed  https://d2wkz7m09tqiv4.cloudfront.net/ef477f3f-0c62-4c6f-9ede-4cbe640e2887

✗ CLUSTER_NAME=cd-rosa-1
✗ OIDC_ID=ef477f3f-0c62-4c6f-9ede-4cbe640e2887

✗ ./rosa create operator-roles --hosted-cp --oidc-config-id $OIDC_ID --mode auto --prefix $CLUSTER_NAME

✗ ./rosa create network \
    --mode auto \
    --param ClusterName=$CLUSTER_NAME \
    --param Name=$CLUSTER_NAME-vpc \
    --param Region=us-east-1 \
    --param VpcCidr=10.0.0.0/16

✗ SUBNETS=$(aws cloudformation describe-stacks --stack-name $CLUSTER_NAME-vpc --query 'Stacks[0].Outputs' --region us-east-1 | jq -r '[ .[] | select(.OutputKey | contains("Subnets")).OutputValue ] | join(",")')

✗ ./rosa create cluster \
    --cluster-name=$CLUSTER_NAME -y \
    --region us-east-1 \
    --operator-roles-prefix $CLUSTER_NAME \
    --subnet-ids $SUBNETS \
    --hosted-cp \
    --multi-az \
    --compute-machine-type m5.xlarge \
    --oidc-config-id $OIDC_ID

✗ ./rosa create machinepool --cluster=$CLUSTER_NAME --name=workers --replicas=2 --instance-type=m5.xlarge --subnet <one of the subnet ids> --region us-east-1

✗ ./rosa list clusters
ID                                    NAME       STATE         TOPOLOGY
145e4852-8146-4c0f-85d3-8c5d24b800f6  cd-rosa-1  Provisioning  Hosted CP

✗ ./rosa list machinepool -c cd-rosa-1
ID       NAME     REPLICAS  INSTANCE TYPE  SUBNET                    STATE
workers  workers  2         m5.xlarge      subnet-0bceee86d866a8efd  Provisioning

✗ ./rosa list machinepool -c cd-rosa-1
ID       NAME     REPLICAS  INSTANCE TYPE  SUBNET                    STATE
workers  workers  2         m5.xlarge      subnet-0bceee86d866a8efd  Ready

✗ ./rosa delete cluster -c cd-rosa-1
? Are you sure you want to delete cluster cd-rosa-1? Yes
I: Cluster 'cd-rosa-1' will start deleting now
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

### ROSA CLI

TBD

## Cluster Lifecycle

**Automatic cleanup:** Clusters are automatically deleted after **24 hours** by a platform cleanup job. You do not need to delete them manually.

**CloudFormation stacks persist:** The three CloudFormation stacks in your AWS account (`cluster-iam`, `cluster-vpc`, `cluster-oidc`) are **not** deleted by the cleanup job. You can reuse them when creating your next cluster with the same name, skipping the `cluster-iam`, `cluster-vpc`, and `cluster-oidc` create steps.

## Notes

- If you create more than 5 hosted clusters, ensure your AWS account has sufficient NAT gateway quota (default limit is 5).
- For ephemeral (dev) environments, see [Development Environment](development-environment.md). The cluster creation flow is the same — only the `API_URL` differs.
- For admin teardown procedures, see [Hosted Cluster Teardown](hostedcluster-teardown.md).
- For assistance, reach out to @rrp-team-ic in #team-rosa-hyperfleet.
