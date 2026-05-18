# Maestro Infrastructure Terraform Module

Provisions AWS infrastructure for Maestro MQTT-based orchestration between Regional and Management clusters.

## Features

- **AWS IoT Core**: MQTT broker with X.509 certificate authentication
- **RDS PostgreSQL**: Maestro Server state database with automated backups
- **Pre-Provisioned Registration**: Management cluster consumer data stored in Secrets Manager
- **EKS Pod Identity**: IAM roles for Server, Agents, and External Secrets Operator
- **Private by Default**: RDS accessible only from EKS cluster security group

## Usage

### Regional Cluster

```hcl
module "maestro_infrastructure" {
  source = "../../modules/maestro-infrastructure"

  # Cluster integration
  regional_id                   = var.regional_id
  vpc_id                        = module.regional_cluster.vpc_id
  private_subnets               = module.regional_cluster.private_subnets
  eks_cluster_name              = module.regional_cluster.cluster_name
  eks_cluster_security_group_id = module.regional_cluster.cluster_security_group_id

  # Management clusters
  management_cluster_count = 2
  management_cluster_ids   = ["mc01", "mc02"]

  # Database configuration (optional)
  db_instance_class       = "db.t4g.micro"
  db_multi_az             = false  # Enable for production
  db_deletion_protection  = false  # Enable for production

  tags = {
    Environment = "development"
  }
}
```

## Variables

| Name                            | Description                                                        | Type           | Default          | Required |
| ------------------------------- | ------------------------------------------------------------------ | -------------- | ---------------- | -------- |
| `regional_id`                   | Regional cluster identifier for resource naming (e.g., `regional`) | `string`       | n/a              | yes      |
| `vpc_id`                        | VPC ID for RDS and security groups                                 | `string`       | n/a              | yes      |
| `private_subnets`               | Private subnet IDs for RDS                                         | `list(string)` | n/a              | yes      |
| `eks_cluster_name`              | EKS cluster name for Pod Identity                                  | `string`       | n/a              | yes      |
| `eks_cluster_security_group_id` | EKS security group for RDS access                                  | `string`       | n/a              | yes      |
| `management_cluster_count`      | Number of management clusters                                      | `number`       | n/a              | yes      |
| `management_cluster_ids`        | List of management cluster IDs                                     | `list(string)` | n/a              | yes      |
| `db_instance_class`             | RDS instance class                                                 | `string`       | `"db.t4g.micro"` | no       |
| `db_allocated_storage`          | RDS storage in GB                                                  | `number`       | `20`             | no       |
| `db_multi_az`                   | Enable Multi-AZ deployment                                         | `bool`         | `false`          | no       |
| `db_deletion_protection`        | Enable deletion protection                                         | `bool`         | `false`          | no       |
| `tags`                          | Additional resource tags                                           | `map(string)`  | `{}`             | no       |

## Outputs

| Name                                   | Description                                 |
| -------------------------------------- | ------------------------------------------- |
| `iot_mqtt_endpoint`                    | AWS IoT Core MQTT endpoint                  |
| `maestro_server_mqtt_cert_secret_name` | Secrets Manager secret for server MQTT cert |
| `maestro_agent_certificates`           | Map of agent certificates by cluster ID     |
| `rds_address`                          | RDS PostgreSQL endpoint                     |
| `rds_port`                             | RDS PostgreSQL port                         |
| `maestro_db_credentials_secret_name`   | Secrets Manager secret for DB credentials   |
| `maestro_server_role_arn`              | IAM role ARN for Maestro Server             |
| `external_secrets_role_arn`            | IAM role ARN for External Secrets Operator  |
| `maestro_configuration_summary`        | Complete Helm configuration summary         |

## Resources Created

- **IoT Core**: Thing, certificate, and policy for server + N agents
- **RDS**: PostgreSQL 16.4 with Performance Insights and 7-day backups
- **Secrets Manager**: Server cert, agent certs, DB credentials, consumer registrations
- **IAM Roles**: Maestro Server, External Secrets Operator (via Pod Identity)
- **Security Groups**: RDS access from EKS cluster only

## Architecture

This module enables MQTT-based communication between Regional Cluster (Maestro Server) and Management Clusters (Maestro Agents):

1. **Server** publishes resource updates to IoT topics
2. **Agents** subscribe to their consumer-specific topics
3. **Network Isolation**: No direct network path between clusters
4. **Pre-Provisioned**: Consumer metadata stored in Secrets Manager

For complete architecture diagrams and message flows, see [Maestro MQTT Resource Distribution](../../../docs/design/maestro-mqtt-resource-distribution.md).

## Cost Estimate

- AWS IoT Core: ~$1-2/month
- RDS db.t4g.micro: ~$15-20/month
- Secrets Manager: ~$0.50/secret/month
- **Total**: ~$20-30/month (varies with cluster count)

## Requirements

- Terraform >= 1.15.3
- AWS Provider >= 6.0
- Regional EKS cluster with Pod Identity enabled
