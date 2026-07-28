# =============================================================================
# ElastiCache Valkey for Platform API Rate Limiting
#
# Single-node Valkey for shared rate limit counters (GCRA algorithm).
# Valkey is the open-source (BSD 3-Clause) fork of Redis, fully compatible
# with go-redis/v9 and redis_rate. 20% cheaper than Redis OSS on ElastiCache.
# No persistence, no AUTH, no backups — counters are ephemeral by design.
# =============================================================================

# Resolve current account ID for the KMS key policy
data "aws_caller_identity" "current" {}

# KMS key for ElastiCache encryption at rest (FedRAMP SC-13).
# Explicit key policy scopes usage to ElastiCache (CKV2_AWS_64) rather than
# relying on the implicit default that grants kms:* to the account root.
resource "aws_kms_key" "elasticache" {
  description             = "KMS key for ElastiCache Valkey encryption at rest (FedRAMP SC-13)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowElastiCacheAccess"
        Effect = "Allow"
        Principal = {
          Service = "elasticache.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*",
          "kms:CreateGrant"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name      = "${var.cluster_id}-elasticache-valkey"
    Component = "rate-limiting"
  }
}

resource "aws_kms_alias" "elasticache" {
  name          = "alias/${var.cluster_id}-elasticache-valkey"
  target_key_id = aws_kms_key.elasticache.key_id
}

# Security Group for ElastiCache Valkey
resource "aws_security_group" "valkey" {
  name        = "${var.cluster_id}-valkey"
  description = "Security group for Platform API rate limiting Valkey"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = false

  tags = {
    Name      = "${var.cluster_id}-valkey-sg"
    Component = "rate-limiting"
  }
}

# Ingress rules as standalone resources — these depend on EKS SG IDs but
# do NOT block the ElastiCache cluster from provisioning.

resource "aws_security_group_rule" "valkey_eks_cluster" {
  type                     = "ingress"
  description              = "Valkey from EKS cluster additional security group"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.valkey.id
  source_security_group_id = var.eks_cluster_security_group_id
}

resource "aws_security_group_rule" "valkey_eks_primary" {
  type                     = "ingress"
  description              = "Valkey from EKS cluster primary security group (Auto Mode)"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.valkey.id
  source_security_group_id = var.eks_cluster_primary_security_group_id
}

# Subnet Group
resource "aws_elasticache_subnet_group" "valkey" {
  name       = "${var.cluster_id}-valkey"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name      = "${var.cluster_id}-valkey-subnet-group"
    Component = "rate-limiting"
  }
}

# Parameter Group
resource "aws_elasticache_parameter_group" "valkey" {
  name   = "${var.cluster_id}-valkey"
  family = "valkey9"

  parameter {
    name  = "maxmemory-policy"
    value = "volatile-ttl"
  }

  tags = {
    Name      = "${var.cluster_id}-valkey-params"
    Component = "rate-limiting"
  }
}

# ElastiCache Valkey Replication Group (single node, no HA, no backups)
# Uses aws_elasticache_replication_group because the AWS CreateCacheCluster
# API (aws_elasticache_cluster) does not support the Valkey engine.
resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id     = "${var.cluster_id}-hf-rl"
  description              = "Platform API rate limiting (Valkey)"
  engine                   = "valkey"
  engine_version           = var.engine_version
  node_type                = var.node_type
  num_node_groups          = 1
  replicas_per_node_group  = 0
  parameter_group_name     = aws_elasticache_parameter_group.valkey.name
  subnet_group_name        = aws_elasticache_subnet_group.valkey.name
  security_group_ids       = [aws_security_group.valkey.id]
  port                     = 6379
  maintenance_window       = "mon:05:00-mon:06:00"
  apply_immediately        = true
  snapshot_retention_limit = 0

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.elasticache.arn

  tags = {
    Name      = "${var.cluster_id}-valkey"
    Component = "rate-limiting"
  }
}
