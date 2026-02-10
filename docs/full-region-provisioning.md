# Complete Guide: Provision a New Region

This comprehensive guide walks through all steps to provision a new region in the ROSA Regional Platform. Follow these steps in order to set up both Regional and Management Clusters with full ArgoCD configuration and Maestro connectivity.

---

## 1. Pre-Flight Checklist

Before starting, ensure your environment is properly configured.

### Required Tools
Verify all tools are installed and accessible:

```bash
# Check tool versions
aws --version
terraform --version
python --version  # or python3 --version
```

### Required AWS accounts

To provision a regional and management cluster, you require two AWS accounts. Ensure you have access to both via environment variables or ideally AWS profiles. 

## 2. ArgoCD Configuration Shard Creation (optional)

<details>
<summary>🔧 Configure New Region Shard (skip if reusing existing environment/region configuration pair)</summary>

**Note:** In case you are deploying clusters based on existing argocd configuration, you can skip this step.
Example: you want to spin up a development cluster and re-use the existing configuration for `env = integration` and `region = us-east-1`.

### Add Region to Configuration

Edit `argocd/config.yaml` and add your new region following this pattern:

```yaml
shards:
  # ... existing entries ...
  - region: "us-west-2"              # ← Your target region
    environment: "integration"       # ← Your environment (integration/staging/etc)
    values:
      management-cluster:
        hypershift:
          oidcStorageS3Bucket:
            name: "hypershift-mc-us-west-2"    # ← Region-specific bucket name
            region: "us-west-2"                # ← Your target region
          externalDns:
            domain: "dev.us-west-2.rosa.example.com"  # ← Region-specific domain
```

### Generate Rendered Configurations

Run the rendering script to generate the required files:

```bash
./argocd/scripts/render.py
```

**Verify rendered files were created:**

```bash
ls -la argocd/rendered/integration/us-west-2/  # Replace with your environment/region
```

You should see directories like `management-cluster-manifests/` and files like `management-cluster-values.yaml`.

### Commit and Push Changes

```bash
git add argocd/config.yaml argocd/rendered/
git commit -m "Add us-west-2 region configuration

- Add us-west-2/integration to argocd/config.yaml
- Generate rendered ArgoCD manifests and values
- Prepare for regional cluster provisioning"
git push origin <your-branch>
```

</details>

---

## 3. Regional Cluster Provisioning

Switch to your **regional account** AWS profile and provision the Regional Cluster.

### Configure Regional Cluster Parameters

In `terraform/config/regional-cluster/terraform.tfvars`, configure:

```bash
# One-time setup: Copy and edit configurations
cp terraform/config/regional-cluster/terraform.tfvars.example \
   terraform/config/regional-cluster/terraform.tfvars
```

### Execute Regional Cluster Provisioning

```bash
# Authenticate with regional account (choose your preferred method)
export AWS_PROFILE=<regional-profile>
# OR: aws configure set profile <regional-profile>
# OR: use your SSO/assume role method

# Provision Regional Environment
make provision-regional
```

<details>
<summary>🔍 Verify Regional Cluster Deployment (optional)</summary>

```bash
# Check ArgoCD applications are synced
./scripts/dev/bastion-connect.sh regional
kubectl get applications -n argocd
```

Expected: ArgoCD applications "Synced" and "Healthy".

</details>

---

## 4. Maestro Connectivity Setup

Maestro uses AWS IoT Core for secure MQTT communication between Regional and Management Clusters. This requires a two-account certificate exchange process.

### Step 4a: Regional Account IoT Setup

**Ensure you're authenticated with the regional account:**

```bash
# Choose your preferred authentication method
export AWS_PROFILE=<regional-profile>
# OR: use --profile flag, SSO, assume role, etc.
```

**Provision IoT resources in regional account:**

```bash
MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars make provision-maestro-agent-iot-regional
```

### Step 4b: Management Account Secret Setup

**Switch to management account authentication:**

```bash
# Choose your preferred authentication method
export AWS_PROFILE=<management-profile>
# OR: use --profile flag, SSO, assume role, etc.
```

**Create IoT secret in management account:**

```bash
MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars make provision-maestro-agent-iot-management
```

**What this creates:**
- Kubernetes secret containing IoT certificate and endpoint
- Configuration for Maestro agent to connect to regional IoT endpoint

<details>
<summary>🔍 Verify IoT Resources (optional)</summary>

```bash
# In regional account - verify IoT endpoint
aws iot describe-endpoint --endpoint-type iot:Data-ATS

# Check certificate is active
aws iot list-certificates
```

Expected: IoT endpoint URL should be returned and certificate should show "ACTIVE" status.

</details>

---

## 5. Management Cluster Provisioning

Switch to your **management account** AWS profile and provision the Management Cluster.

### Configure Management Cluster Parameters

In `terraform/config/management-cluster/terraform.tfvars`, configure:

```bash
# One-time setup: Copy and edit configurations
cp terraform/config/management-cluster/terraform.tfvars.example \
   terraform/config/management-cluster/terraform.tfvars
```

### Execute Management Cluster Provisioning

```bash
# Authenticate with management account (choose your preferred method)
export AWS_PROFILE=<management-profile>
# OR: aws configure set profile <management-profile>
# OR: use your SSO/assume role method

# Provision Management Environment
make provision-management
```
<details>
<summary>🔍 Verify Management Cluster Deployment (optional)</summary>

```bash
# Check cluster is provisioned
./scripts/dev/bastion-connect.sh management

# Verify ArgoCD applications
kubectl get applications -n argocd
```

Expected: ArgoCD applications "Synced" and "Healthy".

</details>

---

## 6. Consumer Registration & Verification

Register the Management Cluster as a consumer with the Regional Cluster's Maestro server.

```bash
API_GATEWAY_URL=$(make terraform-output-regional | jq -r '.api_gateway_invoke_url.value')

awscurl -X POST $API_GATEWAY_URL/api/v0/management_clusters \
--service execute-api \
--region $REGION \
-H "Content-Type: application/json" \
-d '{"name": "management-01", "labels": {"cluster_type": "management", "cluster_id": "management-01"}}'
```

---

## 7. End-to-End Verification

This section provides comprehensive validation that both Regional and Management clusters are running and can communicate properly via Maestro.

<details>
<summary>🔍 Consumer Registration Verification</summary>


```bash
# Verify the Management Cluster is properly registered
# Access the Platform API, and query the registered consumers.
# You can get the gateway api from the regional cluster terraform output

awscurl --service execute-api --region $REGION $API_GATEWAY_URL/api/v0/management_clusters

# example:
# awscurl --service execute-api --region us-east-2 https://z0l5l43or4.execute-api.us-east-2.amazonaws.com/prod/api/v0/management_clusters | jq -r '.items[] | "- \(.name) (labels: \(.labels))"'
```

**Expected Results:**
- Your Management Cluster name appears in the consumer list
- Consumer has appropriate labels (cluster_type, cluster_id)
- No connection errors when accessing Maestro API

</details>

<details>
<summary>🔍 Complete Maestro Payload Distribution Test</summary>

This comprehensive test validates end-to-end Maestro payload distribution from Regional to Management Cluster via AWS IoT Core MQTT using the proper gRPC client interface:

**Step 0: Ensure environment variables**

```bash
export API_GATEWAY_URL=$(make terraform-output-regional | jq -r '.api_gateway_invoke_url.value')
export REGION=<aws region goes here>

```

**Step 1: Create Test ManifestWork File**

```bash
# Create a test ManifestWork JSON file
TIMESTAMP=$(date +%s)

cat > /tmp/maestro-test-manifestwork.json << EOF
{
  "apiVersion": "work.open-cluster-management.io/v1",
  "kind": "ManifestWork",
  "metadata": {
    "name": "maestro-payload-test-${TIMESTAMP}"
  },
  "spec": {
    "workload": {
      "manifests": [
        {
          "apiVersion": "v1",
          "kind": "ConfigMap",
          "metadata": {
            "name": "maestro-payload-test",
            "namespace": "default",
            "labels": {
              "test": "maestro-distribution",
              "timestamp": "${TIMESTAMP}"
            }
          },
          "data": {
            "message": "Hello from Regional Cluster via Maestro MQTT",
            "cluster_source": "regional-cluster",
            "cluster_destination": "${MANAGEMENT_CLUSTER}",
            "transport": "aws-iot-core-mqtt",
            "test_id": "${TIMESTAMP}",
            "payload_size": "This tests MQTT payload distribution through AWS IoT Core"
          }
        }
      ]
    },
    "deleteOption": {
      "propagationPolicy": "Foreground"
    },
    "manifestConfigs": [
      {
        "resourceIdentifier": {
          "group": "",
          "resource": "configmaps",
          "namespace": "default",
          "name": "maestro-payload-test"
        },
        "feedbackRules": [
          {
            "type": "JSONPaths",
            "jsonPaths": [
              {
                "name": "status",
                "path": ".metadata"
              }
            ]
          }
        ],
        "updateStrategy": {
          "type": "ServerSideApply"
        }
      }
    ]
  }
}
EOF

echo "Created ManifestWork file: maestro-payload-test-${TIMESTAMP}"

cat > payload.json << EOF
{
  "cluster_id": "management-01",
  "data": $(cat /tmp/maestro-test-manifestwork.json )
}
EOF
```

**Step 2: Post the payload**

```bash
awscurl -X POST $API_GATEWAY_URL/api/v0/work --service execute-api --region $REGION -d @payload.json
```

**Step 3: Monitor Distribution Status**

```bash
# List the current management_clusters
awscurl --service execute-api --region $REGION $API_GATEWAY_URL/api/v0/management_clusters

# List all ManifestWorks, jq to filter by consumer
awscurl --service execute-api --region $REGION $API_GATEWAY_URL/api/v0/resource_bundles

# Examples:
# awscurl --service execute-api --region us-east-2 https://z0l5l43or4.execute-api.us-east-2.amazonaws.com/prod/api/v0/management_clusters

# awscurl --service execute-api --region us-east-2 https://z0l5l43or4.execute-api.us-east-2.amazonaws.com/prod/api/v0/resource_bundles | jq -r '.items[].status.resourceStatus[]'
```

</details>

