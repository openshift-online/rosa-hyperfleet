# =============================================================================
# HyperFleet DB Module
#
# Provisions an Aurora PostgreSQL cluster with I/O Optimized storage for the
# HyperFleet CR store. Aurora provides automatic storage scaling (up to 128 TB),
# 6-way replication across 3 AZs, and I/O Optimized eliminates per-IOPS billing.
# =============================================================================

data "aws_caller_identity" "current" {}

# =============================================================================
# Networking
# =============================================================================

resource "aws_db_subnet_group" "hyperfleet_db" {
  name        = "${var.cluster_id}-hyperfleet-db"
  description = "HyperFleet DB Aurora subnet group"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name = "${var.cluster_id}-hyperfleet-db"
  }
}

resource "aws_security_group" "hyperfleet_db" {
  name        = "${var.cluster_id}-hyperfleet-db"
  description = "Allow PostgreSQL access from VPC to HyperFleet DB Aurora"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_id}-hyperfleet-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "hyperfleet_db_postgres" {
  security_group_id = aws_security_group.hyperfleet_db.id
  description       = "Allow PostgreSQL from VPC"
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# =============================================================================
# KMS Key for Aurora Encryption at Rest
# =============================================================================

resource "aws_kms_key" "hyperfleet_db" {
  description             = "KMS key for HyperFleet DB Aurora encryption at rest"
  deletion_window_in_days = 7
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
        Sid    = "AllowRDSServiceAccess"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:ListGrants"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "rds.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.cluster_id}-hyperfleet-db"
  }
}

resource "aws_kms_alias" "hyperfleet_db" {
  name          = "alias/${var.cluster_id}-hyperfleet-db"
  target_key_id = aws_kms_key.hyperfleet_db.key_id
}

data "aws_region" "current" {}

# =============================================================================
# Aurora Parameter Groups
#
# Aurora requires separate cluster-level and instance-level parameter groups.
# Cluster parameters control engine-wide settings (SSL, extensions);
# instance parameters control per-instance behavior (logging).
# =============================================================================

resource "aws_rds_cluster_parameter_group" "hyperfleet_db" {
  name        = "${var.cluster_id}-hyperfleet-db-aurora-pg16-cluster"
  family      = "aurora-postgresql16"
  description = "HyperFleet DB Aurora PostgreSQL 16 cluster parameters"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.cluster_id}-hyperfleet-db-aurora-pg16-cluster"
  }
}

resource "aws_db_parameter_group" "hyperfleet_db" {
  name        = "${var.cluster_id}-hyperfleet-db-aurora-pg16"
  family      = "aurora-postgresql16"
  description = "HyperFleet DB Aurora PostgreSQL 16 instance parameters"

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = {
    Name = "${var.cluster_id}-hyperfleet-db-aurora-pg16"
  }
}

# =============================================================================
# IAM Role for Enhanced Monitoring
# =============================================================================

resource "aws_iam_role" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name = "${var.cluster_id}-hyperfleet-db-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.cluster_id}-hyperfleet-db-monitoring"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# =============================================================================
# Master Password (Secrets Manager)
# =============================================================================

resource "aws_secretsmanager_secret" "master" {
  name                    = "${var.cluster_id}-hyperfleet-db-master-password"
  description             = "HyperFleet DB Aurora master password"
  kms_key_id              = aws_kms_key.hyperfleet_db.arn
  recovery_window_in_days = 7

  tags = {
    Name = "${var.cluster_id}-hyperfleet-db-master-password"
  }
}

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id     = aws_secretsmanager_secret.master.id
  secret_string = random_password.master.result
}

# =============================================================================
# Aurora PostgreSQL Cluster
# =============================================================================

resource "aws_rds_cluster" "hyperfleet_db" {
  cluster_identifier = "${var.cluster_id}-hyperfleet-db"

  engine         = "aurora-postgresql"
  engine_version = var.engine_version

  storage_type      = "aurora-iopt1"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.hyperfleet_db.arn

  database_name   = var.database_name
  master_username = "hyperfleet"
  master_password = random_password.master.result

  db_subnet_group_name            = aws_db_subnet_group.hyperfleet_db.name
  vpc_security_group_ids          = [aws_security_group.hyperfleet_db.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.hyperfleet_db.name

  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:05:00-sun:06:00"
  copy_tags_to_snapshot        = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.cluster_id}-hyperfleet-db-final"

  iam_database_authentication_enabled = true

  tags = {
    Name      = "${var.cluster_id}-hyperfleet-db"
    Component = "hyperfleet-db"
    ManagedBy = "terraform"
  }
}

# =============================================================================
# Aurora PostgreSQL Writer Instance
# =============================================================================

resource "aws_rds_cluster_instance" "hyperfleet_db" {
  identifier         = "${var.cluster_id}-hyperfleet-db-writer"
  cluster_identifier = aws_rds_cluster.hyperfleet_db.id

  engine         = aws_rds_cluster.hyperfleet_db.engine
  engine_version = aws_rds_cluster.hyperfleet_db.engine_version
  instance_class = var.instance_class

  db_parameter_group_name = aws_db_parameter_group.hyperfleet_db.name
  publicly_accessible     = false

  performance_insights_enabled    = var.performance_insights_enabled
  performance_insights_kms_key_id = var.performance_insights_enabled ? aws_kms_key.hyperfleet_db.arn : null

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null

  auto_minor_version_upgrade = true

  tags = {
    Name      = "${var.cluster_id}-hyperfleet-db-writer"
    Component = "hyperfleet-db"
    ManagedBy = "terraform"
  }
}

# =============================================================================
# DSN Secret (Secrets Manager)
#
# Stores the full connection string for consumption by External Secrets
# Operator. The operator and platform-api pods read this via the
# hyperfleet-db-dsn Kubernetes Secret.
# =============================================================================

resource "aws_secretsmanager_secret" "dsn" {
  name                    = "${var.cluster_id}-hyperfleet-db-dsn"
  description             = "HyperFleet DB PostgreSQL DSN for operator and platform-api"
  kms_key_id              = aws_kms_key.hyperfleet_db.arn
  recovery_window_in_days = 7

  tags = {
    Name      = "${var.cluster_id}-hyperfleet-db-dsn"
    Component = "hyperfleet-db"
    ManagedBy = "terraform"
  }
}

resource "aws_secretsmanager_secret_version" "dsn" {
  secret_id = aws_secretsmanager_secret.dsn.id
  secret_string = join("", [
    "postgres://",
    aws_rds_cluster.hyperfleet_db.master_username,
    ":",
    random_password.master.result,
    "@",
    aws_rds_cluster.hyperfleet_db.endpoint,
    "/",
    aws_rds_cluster.hyperfleet_db.database_name,
    "?sslmode=require",
  ])
}
