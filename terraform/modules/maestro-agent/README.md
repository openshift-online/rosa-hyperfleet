# Maestro Agent Terraform Module

Provisions IAM roles and Pod Identity for Maestro Agent in management clusters to connect to regional AWS IoT Core.

## Features

- **Cross-Account IoT Access**: Connects to IoT Core in regional AWS account
- **Local Secret Access**: Reads MQTT certificates from Secrets Manager (same account)
- **EKS Pod Identity**: IAM authentication with least-privilege permissions
- **Manual Secret Management**: Certificate data kept out of Terraform state

## Prerequisites

**IMPORTANT:** This module references an existing Secrets Manager secret - you must create it manually before running Terraform.

```bash
# 1. Receive cert.json from regional cluster operator
# 2. Create secret in management cluster account
aws secretsmanager create-secret \
  --name "mc01-maestro-agent-cert" \
  --secret-string file://cert.json

# 3. Securely delete local copy
shred -u cert.json
```

**Why manual?** Keeps sensitive data out of Terraform state and variables.

## Usage

### Management Cluster

```hcl
module "maestro_agent" {
  source = "../../modules/maestro-agent"

  management_id           = "mc01"
  regional_aws_account_id = "123456789012"  # Regional cluster account
  eks_cluster_name        = module.management_cluster.cluster_name

  # Optional overrides
  # mqtt_cert_secret_name = "custom/path/to/secret"
  # mqtt_topic_prefix     = "sources/<regional_id>/consumers"  # Must match the regional cluster's regional_id

  tags = {
    Environment = "production"
  }
}

# Output for Helm deployment
output "maestro_agent_helm_values" {
  value     = module.maestro_agent.helm_values
  sensitive = false
}
```

## Variables

| Name                      | Description                                                                                                             | Type          | Default                              | Required |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------- | ------------------------------------ | -------- |
| `management_id`           | Management cluster identifier (e.g., `mc01`)                                                                            | `string`      | n/a                                  | yes      |
| `regional_aws_account_id` | Regional cluster AWS account ID                                                                                         | `string`      | n/a                                  | yes      |
| `eks_cluster_name`        | EKS cluster name                                                                                                        | `string`      | n/a                                  | yes      |
| `mqtt_cert_secret_name`   | Override default secret path                                                                                            | `string`      | `{management_id}-maestro-agent-cert` | no       |
| `mqtt_topic_prefix`       | MQTT topic prefix — must match `sources/{regional_id}/consumers` where `regional_id` is the Regional Cluster identifier | `string`      | `sources/maestro/consumers`          | no       |
| `tags`                    | Additional resource tags                                                                                                | `map(string)` | `{}`                                 | no       |

## Outputs

| Name                                  | Description                    |
| ------------------------------------- | ------------------------------ |
| `maestro_agent_mqtt_cert_secret_name` | Secrets Manager secret name    |
| `maestro_agent_role_arn`              | IAM role ARN for Pod Identity  |
| `helm_values`                         | Complete Helm values structure |

## Resources Created

- `aws_iam_role.maestro_agent` - Pod Identity role with trust policy
- `aws_iam_role_policy.maestro_agent_secrets` - Read access to MQTT cert secret
- `aws_iam_role_policy.maestro_agent_iot` - Cross-account IoT Core permissions
- `aws_eks_pod_identity_association.maestro_agent` - Binds role to `maestro` namespace

## Deployment Workflow

### 1. Regional Operator: Extract Certificate

```bash
cd terraform/config/regional-cluster
terraform output -json maestro_agent_certificates | jq '.["mc01"]' > cert.json
```

### 2. Secure Transfer

Transfer `cert.json` to management operator via encrypted channel (GPG, AWS Secrets Manager, HashiCorp Vault).

### 3. Management Operator: Create Secret

```bash
aws secretsmanager create-secret \
  --name "mc01-maestro-agent-cert" \
  --secret-string file://cert.json
shred -u cert.json
```

### 4. Apply Terraform

```bash
cd terraform/config/management-cluster
terraform apply
```

### 5. Deploy Helm Chart

```bash
helm upgrade --install maestro-agent charts/maestro-agent \
  -n maestro --create-namespace \
  -f <(terraform output -json maestro_agent_helm_values | jq -r)
```

## Certificate Rotation

Rotate certificates without pod restarts:

```bash
# 1. Regional operator: Generate new certificate
cd terraform/config/regional-cluster
terraform apply

# 2. Extract and securely transfer new cert

# 3. Management operator: Update secret (no Terraform needed)
aws secretsmanager update-secret \
  --secret-id "mc01-maestro-agent-cert" \
  --secret-string file://new-cert.json

# 4. AWS Secrets CSI Driver auto-remounts (~30s)
# 5. Agent reconnects automatically
```

## Troubleshooting

**Secret not found during Terraform apply**

```
Error: reading Secrets Manager Secret: ResourceNotFoundException
```

Create the secret first (see Prerequisites).

**Agent cannot connect to IoT**

- Verify `regional_aws_account_id` matches IoT Core account
- Check IoT policy allows cross-account access from management account
- Review CloudWatch logs in agent pod

## Requirements

- Terraform >= 1.15.3
- AWS Provider >= 6.0
- EKS cluster with Pod Identity enabled
- Pre-existing Secrets Manager secret with MQTT certificate
