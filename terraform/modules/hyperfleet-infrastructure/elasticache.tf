# =============================================================================
# ElastiCache Valkey for Platform API Rate Limiting
#
# Single-node Valkey for shared rate limit counters (GCRA algorithm).
# Valkey is the open-source (BSD 3-Clause) fork of Redis, fully compatible
# with go-redis/v9 and redis_rate. 20% cheaper than Redis OSS on ElastiCache.
# No persistence, no AUTH, no backups — counters are ephemeral by design.
# Gated by enable_rate_limit_redis (default: true).
# =============================================================================

# Security Group for ElastiCache Valkey
# Ingress rules are standalone resources so the SG (and ElastiCache) can
# provision in parallel with EKS, rather than waiting for EKS security group IDs.
resource "aws_security_group" "hyperfleet_redis" {
  count = var.enable_rate_limit_redis ? 1 : 0

  name        = "${var.regional_id}-hyperfleet-redis"
  description = "Security group for Platform API rate limiting Valkey"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = false

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-redis-sg"
      Component = "rate-limiting"
    }
  )
}

# Ingress rules as standalone resources — these depend on EKS SG IDs but
# do NOT block the ElastiCache cluster from provisioning.

resource "aws_security_group_rule" "hyperfleet_redis_eks_cluster" {
  count = var.enable_rate_limit_redis ? 1 : 0

  type                     = "ingress"
  description              = "Valkey from EKS cluster additional security group"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.hyperfleet_redis[0].id
  source_security_group_id = var.eks_cluster_security_group_id
}

resource "aws_security_group_rule" "hyperfleet_redis_eks_primary" {
  count = var.enable_rate_limit_redis ? 1 : 0

  type                     = "ingress"
  description              = "Valkey from EKS cluster primary security group (Auto Mode)"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.hyperfleet_redis[0].id
  source_security_group_id = var.eks_cluster_primary_security_group_id
}

resource "aws_security_group_rule" "hyperfleet_redis_bastion" {
  count = var.enable_rate_limit_redis && var.bastion_enabled ? 1 : 0

  type                     = "ingress"
  description              = "Valkey from bastion"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.hyperfleet_redis[0].id
  source_security_group_id = var.bastion_security_group_id
}

# Subnet Group
resource "aws_elasticache_subnet_group" "hyperfleet" {
  count = var.enable_rate_limit_redis ? 1 : 0

  name       = "${var.regional_id}-hyperfleet-redis"
  subnet_ids = var.private_subnets

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-redis-subnet-group"
      Component = "rate-limiting"
    }
  )
}

# Parameter Group
resource "aws_elasticache_parameter_group" "hyperfleet" {
  count = var.enable_rate_limit_redis ? 1 : 0

  name   = "${var.regional_id}-hyperfleet-redis"
  family = "valkey9"

  parameter {
    name  = "maxmemory-policy"
    value = "volatile-ttl"
  }

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-redis-params"
      Component = "rate-limiting"
    }
  )
}

# ElastiCache Valkey Replication Group (single node, no HA, no backups)
# Uses aws_elasticache_replication_group because the AWS CreateCacheCluster
# API (aws_elasticache_cluster) does not support the Valkey engine.
resource "aws_elasticache_replication_group" "hyperfleet" {
  count = var.enable_rate_limit_redis ? 1 : 0

  replication_group_id     = "${var.regional_id}-hf-rl"
  description              = "Platform API rate limiting (Valkey)"
  engine                   = "valkey"
  engine_version           = var.valkey_engine_version
  node_type                = var.valkey_node_type
  num_node_groups          = 1
  replicas_per_node_group  = 0
  parameter_group_name     = aws_elasticache_parameter_group.hyperfleet[0].name
  subnet_group_name        = aws_elasticache_subnet_group.hyperfleet[0].name
  security_group_ids       = [aws_security_group.hyperfleet_redis[0].id]
  port                     = 6379
  maintenance_window       = "mon:05:00-mon:06:00"
  apply_immediately        = true
  snapshot_retention_limit = 0

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-redis"
      Component = "rate-limiting"
    }
  )
}
