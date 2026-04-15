# Provision a New Hosted Cluster

## Prerequisites

### ROSA Regional Platform CLI

```bash
# Clone the repository
git clone https://github.com/openshift-online/rosa-regional-platform-cli.git
cd rosa-regional-platform-cli

# Build
make build

# Install globally (optional)
make install
```

### Dependencies

```bash
command -v jq >/dev/null || echo "Need jq installed"
command -v awscurl >/dev/null || echo "Need awscurl installed"
```

- [awscurl](https://github.com/okigan/awscurl)

## Set AWS account

```bash
# assume role into the "customer" account
# you can create hcp from any aws account, but just to ensure separation
# you can use a separate account to mimic a customer workflow. Set this
# to be any AWS profile to an account you have access to.
export AWS_PROFILE=rrp-customer-dev
```

## Using the rosactl command

### Gather Data

```bash
# 1. Get the API_URL, this is output as part of your ephemeral environment or use integration
# Example raw ephemeral API Gateway URL:
# API_URL=https://ra15lectz3.execute-api.us-east-1.amazonaws.com/prod
# or use our integration env
API_URL=https://api.us-east-1.int0.rosa.devshift.net

# 2. Set your Cluster Variables
REGION=us-east-1
AZ=${REGION}a
CLUSTER_NAME=
```

<details>
  <summary>Ensure your AWS Account is allowlisted in the environment (only needs to be run once per environment)</summary>
  
#### Ephemeral Environment Account Whitelisting

```bash
# 1. Get your account ID:
ACCOUNT=$(aws sts get-caller-identity | jq -r .Account)

# 2. Ensure you have the the variables from above ready to use in the next section:
# Helper output to give you all the variables again if they've scrolled out of view:
echo "ACCOUNT=${ACCOUNT} REGION=${REGION}"

# Create a shell to the platform api
make ephemeral-shell

# Paste the output from the `echo` command above into the bastion session to set the env vars, and then run:
awscurl --service execute-api --region "${REGION}" -X POST "${API_URL}/api/v0/accounts" -H "Content-Type: application/json" -d "{\"accountId\": \"${ACCOUNT}\", \"privileged\": true}"
```

#### Integration/Staging Environment Account Whistelisting

Have an already-privileged user allow your account. Provide your account to the user, and then they run:

```bash
ACCOUNT=
API_URL=https://api.int0.rosa.devshift.net
REGION=us-east-1
awscurl --service execute-api --region "${REGION}" -X POST "${API_URL}/api/v0/accounts" -H "Content-Type: application/json" -d "{\"accountId\": \"${ACCOUNT}\", \"privileged\": true}"
```

---

</details>

```bash
# 1. set the reference to the platform api
rosactl login --url $API_URL

# 1. setup iam in the customer account (via cloudformation stack)
rosactl cluster-iam create $CLUSTER_NAME --region $REGION

# 2. setup vpc for the hosted cluster. Currently, we only support HCP with 1 az.
# (also cloudformation stack)
rosactl cluster-vpc create $CLUSTER_NAME --region $REGION --availability-zones $AZ

# 3. submit the cluster creation to the platform api
# --placement (required only in ephemeral environment)
PLACEMENT=$(awscurl --service execute-api $API_URL/api/v0/management_clusters --region $REGION | jq -r '.items[0].name')

rosactl cluster create $CLUSTER_NAME --region $REGION --placement $PLACEMENT | tee /tmp/$CLUSTER_NAME.json

# export CLOUDURL with the value of cloudUrl in the response above
CLOUDURL=$(jq -r '.spec.cloudUrl' < /tmp/$CLUSTER_NAME.json)

# 4. create the oidc for the hcp
rosactl cluster-oidc create $CLUSTER_NAME --region $REGION --oidc-issuer-url $CLOUDURL
```

# Tear Down a Hosted Cluster (Temporary)

> **Note:** This is a temporary workaround while cluster deletion through the
> Platform API / CLM is not yet supported.
>
> **This procedure is restricted to RRP administrators only.** It requires
> break-glass access to the Regional and Management Clusters, which is not
> available to regular users.

## Overview

The full teardown flow is:

1. Delete the cluster record from the `clusters` table (RC)
2. Delete the cluster record from the `adapter_statuses` table (RC)
3. Delete the resource bundles via the Platform API
4. Wait for the HostedCluster and NodePool to be removed from the MC
5. Delete the CloudFormation stacks in the customer AWS account (TODO)

## Step 1 & 2 — Clean Up the CLM Database (Regional Cluster)

Open a bastion session to the Regional Cluster:

```bash
# For the integration environment:
make int-bastion-rc

# For an ephemeral environment:
make ephemeral-bastion-rc
```

Once connected, run the cleanup script below. The script connects to the CLM
database, lists all clusters, and lets you choose to delete a single cluster or
all clusters. It removes records from both the `clusters` and
`adapter_statuses` tables.

<details>
<summary>cleanup-clm-db.sh</summary>

```bash
#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${YELLOW}ℹ $1${NC}"; }

for cmd in oc jq psql; do
    if ! command -v "$cmd" &>/dev/null; then
        print_error "$cmd command not found. Please install it."
        exit 1
    fi
done

NAMESPACE="hyperfleet-system"
SECRET_NAME="hyperfleet-api-db-credentials"

print_header "Retrieving database credentials from Kubernetes secret"

if ! DB_USER=$(oc get secret -n "$NAMESPACE" "$SECRET_NAME" \
    -o jsonpath='{.data.db\.user}' 2>/dev/null | base64 -d); then
    print_error "Failed to retrieve secret $SECRET_NAME from namespace $NAMESPACE"
    print_info "Make sure you're logged into the cluster and the secret exists"
    exit 1
fi

DB_PASSWORD=$(oc get secret -n "$NAMESPACE" "$SECRET_NAME" -o jsonpath='{.data.db\.password}' | base64 -d)
DB_HOST=$(oc get secret -n "$NAMESPACE" "$SECRET_NAME" -o jsonpath='{.data.db\.host}' | base64 -d)
DB_PORT=$(oc get secret -n "$NAMESPACE" "$SECRET_NAME" -o jsonpath='{.data.db\.port}' | base64 -d)
DB_NAME="hyperfleet"
DB_PORT="${DB_PORT:-5432}"

if [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_HOST" ]; then
    print_error "One or more database credentials are empty"
    exit 1
fi

print_success "Retrieved database credentials"
print_info "Host: $DB_HOST | Port: $DB_PORT | Database: $DB_NAME | User: $DB_USER"

export PGPASSWORD="$DB_PASSWORD"

print_header "Connecting to PostgreSQL database"
if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" &>/dev/null; then
    print_error "Failed to connect to database at $DB_HOST:$DB_PORT"
    exit 1
fi
print_success "Successfully connected to database"

print_header "Listing all active clusters"

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
SELECT id, name, kind, generation, created_time, updated_time
FROM clusters
WHERE deleted_at IS NULL
ORDER BY created_time DESC;
"

CLUSTER_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT COUNT(*) FROM clusters WHERE deleted_at IS NULL;")
print_info "Total active clusters: $CLUSTER_COUNT"

if [ "$CLUSTER_COUNT" -eq 0 ]; then
    print_info "No clusters to delete."
    unset PGPASSWORD
    exit 0
fi

echo ""
echo "Options:"
echo "  1) Delete a single cluster (by name)"
echo "  2) Delete ALL clusters"
read -rp "Choose an option [1/2]: " OPTION

case "$OPTION" in
    1)
        read -rp "Enter the cluster name to delete: " CLUSTER_NAME
        CLUSTER_ID=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
            "SELECT id FROM clusters WHERE name = '$CLUSTER_NAME' AND deleted_at IS NULL;")
        if [ -z "$CLUSTER_ID" ]; then
            print_error "No active cluster found with name '$CLUSTER_NAME'"
            unset PGPASSWORD
            exit 1
        fi
        CLUSTERS_WHERE="WHERE name = '$CLUSTER_NAME'"
        ADAPTER_WHERE="WHERE resource_id = '$CLUSTER_ID'"
        DELETE_DESC="cluster '$CLUSTER_NAME'"
        ;;
    2)
        CLUSTERS_WHERE=""
        ADAPTER_WHERE=""
        DELETE_DESC="ALL clusters"
        ;;
    *)
        print_error "Invalid option"
        unset PGPASSWORD
        exit 1
        ;;
esac

ADAPTER_TABLE_EXISTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'adapter_statuses');")

echo ""
print_info "WARNING: This will delete $DELETE_DESC from the CLM database!"
if [ "$ADAPTER_TABLE_EXISTS" = "t" ]; then
    print_info "This will also delete matching records from the adapter_statuses table."
fi
read -rp "Type 'yes' to confirm: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    print_info "Deletion cancelled."
    unset PGPASSWORD
    exit 0
fi

print_header "Step 1: Deleting $DELETE_DESC from clusters table"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "DELETE FROM clusters $CLUSTERS_WHERE;"
print_success "Deleted $DELETE_DESC from clusters table"

if [ "$ADAPTER_TABLE_EXISTS" = "t" ]; then
    print_header "Step 2: Deleting matching records from adapter_statuses table"
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "DELETE FROM adapter_statuses $ADAPTER_WHERE;"
    print_success "Deleted matching records from adapter_statuses table"
fi

print_header "Verifying deletion"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
    "SELECT COUNT(*) AS remaining_clusters FROM clusters WHERE deleted_at IS NULL;"

echo ""
if [ "$OPTION" = "1" ]; then
    print_info "Copy this cluster ID for Step 3 (resource bundle deletion):"
    echo "  $CLUSTER_ID"
fi

unset PGPASSWORD
print_success "Database cleanup complete!"
```

</details>

## Step 3 — Delete Resource Bundles (Platform API)

Open a Platform API shell:

```bash
# For the integration environment:
make int-shell

# For an ephemeral environment:
make ephemeral-shell
```

Run the following script to find and delete all resource bundles for a cluster.
It handles pagination automatically:

```bash
read -rp "Enter cluster ID: " CLUSTER_ID
echo "Searching for bundles matching '$CLUSTER_ID'..."
for page in $(seq 1 10); do
  RESP=$(awscurl --service execute-api "$API_URL/api/v0/resource_bundles?page=$page&size=100")
  echo "$RESP" | jq -r ".items[] | select(.metadata.name | contains(\"$CLUSTER_ID\")) | .id"
done | sort -u | while read -r BUNDLE_ID; do
  echo "Deleting bundle: $BUNDLE_ID"
  awscurl -X DELETE --service execute-api "$API_URL/api/v0/resource_bundles/$BUNDLE_ID"
  echo "Done: $BUNDLE_ID"
done
```

## Step 4 — Wait for HostedCluster and NodePool Removal (Management Cluster)

After deleting the resource bundles, Maestro will propagate the deletion to the
Management Cluster. **Wait for the HostedCluster and NodePool resources to be
fully removed from the MC** before proceeding.

Bastion into the MC to verify:

```bash
# For the integration environment:
make int-bastion-mc

# For an ephemeral environment:
make ephemeral-bastion-mc
```

```bash
# Confirm resources are gone
oc get hostedcluster -A | grep <cluster_name>
oc get nodepools.hypershift.openshift.io -A | grep <cluster_name>
```

Both commands should return no results.

## Step 5 — Delete CloudFormation Stacks (Customer AWS Account)

Switch to the customer AWS account and delete the CloudFormation stacks
associated with the cluster:

```bash
export AWS_PROFILE=rrp-customer-dev

# List stacks related to the cluster
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?contains(StackName, '<cluster_name>')]" \
  --output table

# Delete each stack
aws cloudformation delete-stack --stack-name <stack_name>

# Wait for deletion to complete
aws cloudformation wait stack-delete-complete --stack-name <stack_name>
```

# Notes

1. if you create more than 5 hcp, make sure your account has more than nat gateway quota. The default is 5.
