# HyperFleet Infrastructure Module

This Terraform module provisions AWS managed services for the HyperFleet cluster lifecycle management system in the ROSA Regional Platform.

## Overview

HyperFleet is the cluster lifecycle management system that orchestrates ROSA HCP cluster provisioning and management. This module migrates HyperFleet from in-cluster PostgreSQL and RabbitMQ to production-ready AWS managed services with Pod Identity authentication.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    EKS Regional Cluster                      │
│                                                              │
│  ┌──────────────┐      ┌──────────────┐   ┌──────────────┐│
│  │ HyperFleet   │      │ HyperFleet   │   │ HyperFleet   ││
│  │ API          │      │ Sentinel     │   │ Adapter      ││
│  │              │      │              │   │              ││
│  │ Pod Identity │      │ Pod Identity │   │ Pod Identity ││
│  └──────┬───────┘      └──────┬───────┘   └──────┬───────┘│
│         │                     │                   │         │
└─────────┼─────────────────────┼───────────────────┼─────────┘
          │                     │                   │
          │ AWS Secrets         │ AWS Secrets       │ AWS Secrets
          │ Manager (DB)        │ Manager (MQ)      │ Manager (MQ)
          │                     │                   │
     ┌────▼─────┐          ┌────▼──────────────────▼────┐
     │   RDS    │          │      Amazon MQ             │
     │PostgreSQL│          │   (RabbitMQ 3.13)          │
     │          │          │                            │
     │db.t4g.   │          │   mq.t3.micro              │
     │micro     │          │   SINGLE_INSTANCE          │
     └──────────┘          └────────────────────────────┘
```

## Resources Created

### Database (RDS PostgreSQL)

- **Instance**: PostgreSQL 18.1 on db.t4g.micro (configurable)
- **Storage**: 20 GB gp3, encrypted at rest
- **High Availability**: Single-AZ (development) or Multi-AZ (production)
- **Backups**: 7-day retention, automated snapshots
- **Monitoring**: Performance Insights enabled (7-day retention)
- **Network**: Private subnets only, no public access
- **Security**: TLS required, security group restricts access to EKS cluster

### Message Queue (Amazon MQ for RabbitMQ)

- **Broker**: RabbitMQ 3.13 on mq.t3.micro (configurable)
- **Deployment**: SINGLE_INSTANCE (development) or CLUSTER_MULTI_AZ (production)
- **Protocol**: AMQPS (port 5671) with TLS encryption
- **Network**: Private subnets only, no public access
- **Management**: RabbitMQ console accessible via bastion/VPN
- **Security**: Encrypted at rest, security group restricts access

### Secrets Management

- **DB Credentials Secret**: `{regional_id}-hyperfleet-db-credentials`
  - Contains: username, password, host, port, database
- **MQ Credentials Secret**: `{regional_id}-hyperfleet-mq-credentials`
  - Contains: username, password, host, port, url (amqps://)
- **Recovery**: 0-day recovery window for quick recreation in dev

### IAM Roles (Pod Identity)

1. **hyperfleet-api**: Access to database credentials
2. **hyperfleet-sentinel**: Access to message queue credentials
3. **hyperfleet-adapter**: Access to message queue credentials

Each role has:

- Trust policy for `pods.eks.amazonaws.com`
- Least-privilege access to specific Secrets Manager secrets
- Pod Identity association to service account in `hyperfleet-system` namespace

## Usage

### Basic Configuration (Development)

```hcl
module "hyperfleet_infrastructure" {
  source = "../../modules/hyperfleet-infrastructure"

  # Required from EKS cluster
  regional_id                           = "regional"
  vpc_id                                = "vpc-xxxxx"
  private_subnets                       = ["subnet-xxxxx", "subnet-yyyyy"]
  eks_cluster_name                      = "regional"
  eks_cluster_security_group_id         = "sg-xxxxx"
  eks_cluster_primary_security_group_id = "sg-yyyyy"
}
```

### Production Configuration

```hcl
module "hyperfleet_infrastructure" {
  source = "../../modules/hyperfleet-infrastructure"

  # ... required variables ...

  # Bastion access for emergency access
  bastion_security_group_id = "sg-bastion"

  # Database configuration
  db_instance_class      = "db.t4g.small"
  db_multi_az            = true
  db_deletion_protection = true

  # Message queue configuration
  mq_instance_type   = "mq.m5.large"
  mq_deployment_mode = "CLUSTER_MULTI_AZ"
}
```

## Inputs

| Name                                  | Description                                                        | Type         | Default         | Required |
| ------------------------------------- | ------------------------------------------------------------------ | ------------ | --------------- | -------- |
| regional_id                           | Regional cluster identifier for resource naming (e.g., `regional`) | string       | -               | yes      |
| vpc_id                                | VPC ID where resources will be deployed                            | string       | -               | yes      |
| private_subnets                       | List of private subnet IDs                                         | list(string) | -               | yes      |
| eks_cluster_name                      | EKS cluster name for Pod Identity                                  | string       | -               | yes      |
| eks_cluster_security_group_id         | EKS cluster additional SG ID                                       | string       | -               | yes      |
| eks_cluster_primary_security_group_id | EKS cluster primary SG ID                                          | string       | -               | yes      |
| bastion_security_group_id             | Optional bastion SG ID                                             | string       | null            | no       |
| db_instance_class                     | RDS instance class                                                 | string       | db.t4g.micro    | no       |
| db_multi_az                           | Enable Multi-AZ for RDS                                            | bool         | false           | no       |
| db_deletion_protection                | Enable deletion protection                                         | bool         | false           | no       |
| mq_instance_type                      | Amazon MQ instance type                                            | string       | mq.t3.micro     | no       |
| mq_deployment_mode                    | Amazon MQ deployment mode                                          | string       | SINGLE_INSTANCE | no       |

## Outputs

| Name                  | Description                                |
| --------------------- | ------------------------------------------ |
| rds_endpoint          | RDS PostgreSQL endpoint (hostname:port)    |
| rds_address           | RDS PostgreSQL hostname                    |
| rds_database_name     | PostgreSQL database name                   |
| mq_amqp_endpoint      | Amazon MQ AMQPS endpoint                   |
| mq_console_url        | RabbitMQ management console URL            |
| db_secret_name        | Database credentials secret name           |
| mq_secret_name        | MQ credentials secret name                 |
| api_role_arn          | HyperFleet API IAM role ARN                |
| sentinel_role_arn     | HyperFleet Sentinel IAM role ARN           |
| adapter_role_arn      | HyperFleet Adapter IAM role ARN            |
| configuration_summary | Complete configuration summary (sensitive) |

## Cost Estimates

### Development Tier (Default)

- **RDS**: db.t4g.micro, Single-AZ, 20GB = ~$13.62/month
- **Amazon MQ**: mq.t3.micro, Single-Instance = ~$15.14/month
- **Secrets Manager**: 2 secrets = ~$0.84/month
- **KMS**: 1 key + requests = ~$1.15/month
- **Total**: ~$30.75/month (~$369/year)

### Production Tier (Recommended)

- **RDS**: db.t4g.small, Multi-AZ, 100GB = ~$80/month
- **Amazon MQ**: mq.m5.large, Multi-AZ cluster = ~$500/month
- **Secrets Manager**: 2 secrets = ~$0.84/month
- **KMS**: 1 key + requests = ~$1.15/month
- **Total**: ~$582/month (~$6,984/year)

## Security

### Network Security

- All resources deployed in private subnets only
- No public endpoints (publicly_accessible = false)
- Security groups restrict access to EKS cluster nodes
- Optional bastion access for emergency troubleshooting

### Data Encryption

- RDS: Encryption at rest (AWS-managed KMS)
- Amazon MQ: Encryption at rest (AWS-managed KMS)
- Secrets Manager: Encrypted storage
- TLS in transit (RDS requires SSL, Amazon MQ uses AMQPS)

### Access Control

- Pod Identity for workload authentication (no static credentials)
- Least-privilege IAM policies (read-only access to specific secrets)
- Service accounts mapped to IAM roles via EKS Pod Identity associations

## Monitoring

### CloudWatch Metrics

**RDS Metrics**:

- DatabaseConnections
- CPUUtilization
- FreeStorageSpace
- ReadLatency / WriteLatency
- FreeableMemory

**Amazon MQ Metrics**:

- CpuUtilization
- HeapUsage
- SystemCpuUtilization
- QueueSize (per queue)
- MessageCount

**Recommended Alarms**:

- RDS CPU > 80%
- RDS Free Storage < 5 GB
- Amazon MQ Queue Depth > 100
- Amazon MQ Heap Usage > 70%

### CloudWatch Logs

- RDS: PostgreSQL logs and upgrade logs
- Amazon MQ: General broker logs

### Performance Insights

- RDS Performance Insights enabled (7-day retention)
- Database query performance analysis
- Wait event analysis

## Disaster Recovery

### RDS Backups

- Automated daily backups (7-day retention by default)
- Backup window: 03:00-04:00 UTC
- Point-in-time recovery (PITR) available
- Manual snapshots supported
- Final snapshot created on deletion (if deletion_protection = true)

### Amazon MQ

- Automated minor version upgrades
- Maintenance window: Monday 04:00-05:00 UTC
- No built-in backup (message queue is ephemeral by design)
- Multi-AZ deployment for HA (production)

### Secrets Rotation

- Secrets Manager supports automatic rotation
- Manual rotation process:
  1. Generate new password in Terraform
  2. Apply infrastructure changes
  3. Restart HyperFleet pods to pick up new credentials

## Troubleshooting

### Connection Issues

**RDS Connection Failures**:

1. Check security group rules allow EKS cluster access
2. Verify Pod Identity role has Secrets Manager permissions
3. Check RDS instance status in AWS Console
4. Verify SSL/TLS is enabled in connection string

**Amazon MQ Connection Failures**:

1. Verify AMQPS endpoint is accessible from EKS VPC
2. Check security group allows port 5671 from EKS
3. Verify Pod Identity credentials are mounted
4. Check broker status in Amazon MQ console

### Pod Identity Issues

**Secrets Not Mounting**:

1. Verify SecretProviderClass exists: `kubectl get secretproviderclass -n hyperfleet-system`
2. Check service account annotation: `kubectl get sa -n hyperfleet-system <sa-name> -o yaml`
3. Verify IAM role trust policy includes `pods.eks.amazonaws.com`
4. Check CSI driver is running: `kubectl get pods -n kube-system | grep csi`

### Performance Issues

**Slow Database Queries**:

1. Check Performance Insights in RDS console
2. Review slow query logs
3. Consider scaling to larger instance class
4. Enable Multi-AZ for production workloads

**Message Queue Lag**:

1. Monitor queue depth in CloudWatch
2. Check consumer (Adapter) is running
3. Verify message processing time
4. Consider scaling to larger instance type

## Migration Path

### From In-Cluster to AWS Managed Services

1. **Deploy Infrastructure**:

   ```bash
   cd terraform/config/regional-cluster
   terraform apply
   ```

2. **Update Helm Values**:
   - Set `hyperfleetApi.database.postgresql.enabled: false`
   - Set `hyperfleetApi.database.external.enabled: true`
   - Set `hyperfleetApi.aws.podIdentity.roleArn` from Terraform output
   - Similar changes for Sentinel and Adapter

3. **Deploy Updated HyperFleet**:

   ArgoCD manages the HyperFleet charts (`hyperfleet-api-chart`, `hyperfleet-sentinel-chart`, `hyperfleet-adapter1-chart`). Sync the relevant ArgoCD applications after updating values.

4. **Verify**:
   - Check pods are running: `kubectl get pods -n hyperfleet-system`
   - Verify secrets mounted: `kubectl exec -n hyperfleet-system <pod> -- ls /mnt/secrets-store`
   - Test database connectivity
   - Test message queue connectivity

### Rollback Plan

If issues occur, revert to in-cluster services:

1. Set `*.postgresql.enabled: true` and `*.external.enabled: false`
2. Redeploy Helm chart
3. AWS resources remain provisioned for investigation

## Maintenance

### Regular Tasks

- Review CloudWatch metrics weekly
- Monitor costs in AWS Cost Explorer
- Update RDS and Amazon MQ during maintenance windows
- Rotate secrets quarterly (or as required by security policy)
- Review and update security groups as needed

### Scaling Considerations

- **RDS**: Scale vertically (larger instance) or enable Multi-AZ
- **Amazon MQ**: Scale vertically or move to cluster deployment
- Monitor usage trends to right-size instances

## Related Documentation

- [HyperFleet Adapter1 Chart](../../../argocd/config/regional-cluster/hyperfleet-adapter1-chart/README.md) - Cluster status reporting and adapter architecture
- [Architecture Overview](../../../docs/README.md) - ROSA Regional Platform three-layer architecture
- [AWS RDS Documentation](https://docs.aws.amazon.com/rds/)
- [Amazon MQ Documentation](https://docs.aws.amazon.com/amazon-mq/)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)

## Support

For issues or questions:

1. Check CloudWatch logs and metrics
2. Review this documentation
3. Consult the troubleshooting section
4. Contact the platform team via Slack #rosa-regional-platform
