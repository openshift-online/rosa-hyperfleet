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

## 6. Consumer Registration

Register the Management Cluster as a consumer with the Regional Cluster's Maestro server.

**Ensure you're authenticated with the regional account:**

```bash
# Choose your preferred authentication method
export AWS_PROFILE=<regional-profile>
# OR: use --profile flag, SSO, assume role, etc.
```

**Register the management cluster:**

```bash
make register-management-consumer MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars
```

This script will:
- Read the `cluster_id` from your management cluster tfvars
- Retrieve the API Gateway URL from regional terraform state
- Register the management cluster as a Maestro consumer with appropriate labels

---

## 7. End-to-End Verification

This section provides comprehensive validation that both Regional and Management clusters are running and can communicate properly via Maestro.

<details>
<summary>🔍 Consumer Registration Verification</summary>

```bash
# Get the API Gateway URL from terraform output
API_GATEWAY_URL=$(cd terraform/config/regional-cluster && terraform output -raw api_gateway_invoke_url)

# Verify the Management Cluster is properly registered
awscurl --service execute-api --region $AWS_REGION \
  "${API_GATEWAY_URL}/api/v0/management_clusters" | jq -r '.items[] | "- \(.name) (labels: \(.labels))"'
```

**Expected Results:**
- Your Management Cluster name appears in the consumer list
- Consumer has appropriate labels (cluster_type, cluster_id)
- No connection errors when accessing Maestro API

</details>

<details>
<summary>🔍 Complete Maestro Payload Distribution Test</summary>

This test validates end-to-end Maestro payload distribution from Regional to Management Cluster via AWS IoT Core MQTT.

**Step 1: Create a test manifest**

```bash
cat > /tmp/maestro-test-configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: maestro-payload-test
  namespace: default
  labels:
    test: maestro-distribution
data:
  message: "Hello from Regional Cluster via Maestro MQTT"
  transport: "aws-iot-core-mqtt"
EOF
```

**Step 2: Deploy to management cluster via Maestro**

```bash
make deploy-manifest \
  MANIFEST=/tmp/maestro-test-configmap.yaml \
  MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars
```

> **Note:** The `deploy-manifest` target wraps your manifest in a ManifestWork with default options (`deleteOption: Foreground`, no `manifestConfigs`). For full control over ManifestWork options like `feedbackRules` or `updateStrategy`, see the detailed example below.

<details>
<summary>📋 Detailed Example: Full ManifestWork with all options</summary>

For full control over the ManifestWork, you can construct the payload manually. This example shows all available options including `manifestConfigs` for feedback rules and update strategies:

```bash
TIMESTAMP=$(date +%s)
MANAGEMENT_CLUSTER="management-01"  # Your cluster_id from tfvars
API_GATEWAY_URL=$(cd terraform/config/regional-cluster && terraform output -raw api_gateway_invoke_url)

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
            "test_id": "${TIMESTAMP}"
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

# Wrap in the API payload format and post
cat > /tmp/payload.json << EOF
{
  "cluster_id": "${MANAGEMENT_CLUSTER}",
  "data": $(cat /tmp/maestro-test-manifestwork.json)
}
EOF

awscurl -X POST "${API_GATEWAY_URL}/api/v0/work" \
  --service execute-api \
  --region $AWS_REGION \
  -H "Content-Type: application/json" \
  -d @/tmp/payload.json
```

</details>

**Step 3: Monitor Distribution Status**

```bash
# Get the API Gateway URL
API_GATEWAY_URL=$(cd terraform/config/regional-cluster && terraform output -raw api_gateway_invoke_url)

# List the current management_clusters
awscurl --service execute-api --region $AWS_REGION \
  "${API_GATEWAY_URL}/api/v0/management_clusters"

# List all resource bundles and check status
awscurl --service execute-api --region $AWS_REGION \
  "${API_GATEWAY_URL}/api/v0/resource_bundles" | jq '.items[].status.resourceStatus[]'
```

**Step 4: Verify on Management Cluster**

```bash
# Connect to management cluster and verify the ConfigMap was created
./scripts/dev/bastion-connect.sh management
kubectl get configmap maestro-payload-test -n default -o yaml
```

</details>

