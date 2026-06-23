# =============================================================================
# RDS PostgreSQL Database for KAS (Kine backend)
#
# Stores Kubernetes API Server state via the Kine etcd-shim, backed by
# PostgreSQL for durability and Multi-AZ HA.
# =============================================================================

# -----------------------------------------------------------------------------
# FedRAMP AU-09: KMS Key for RDS CloudWatch Log Encryption
# -----------------------------------------------------------------------------

resource "aws_kms_key" "rds_logs" {
  description             = "KMS key for KAS RDS CloudWatch log encryption (FedRAMP AU-09)"
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
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.id}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/rds/instance/${var.regional_id}-kas/*"
          }
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-kas-rds-logs"
      Component = "kas"
    }
  )
}

resource "aws_kms_alias" "rds_logs" {
  name          = "alias/${var.regional_id}-kas-rds-logs"
  target_key_id = aws_kms_key.rds_logs.key_id
}

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = "/aws/rds/instance/${var.regional_id}-kas/postgresql"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.rds_logs.arn

  tags = merge(local.common_tags, {
    Name      = "${var.regional_id}-kas-rds-postgresql-logs"
    Component = "kas"
  })
}

resource "aws_cloudwatch_log_group" "rds_upgrade" {
  name              = "/aws/rds/instance/${var.regional_id}-kas/upgrade"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.rds_logs.arn

  tags = merge(local.common_tags, {
    Name      = "${var.regional_id}-kas-rds-upgrade-logs"
    Component = "kas"
  })
}

# Generate secure random password for database
resource "random_password" "db_password" {
  length  = 32
  special = true
  # Exclude characters that might cause issues in connection strings
  override_special = "!#$%&*()-_=+[]{}:?"
}

# DB Subnet Group spanning multiple AZs
resource "aws_db_subnet_group" "kas" {
  name       = "${var.regional_id}-kas-db"
  subnet_ids = var.private_subnets

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-kas-db-subnet-group"
      Component = "kas"
    }
  )
}

# Security Group for RDS
# Ingress rules are standalone resources so the SG (and RDS) can provision
# in parallel with EKS, rather than waiting for EKS security group IDs.
resource "aws_security_group" "kas_db" {
  name        = "${var.regional_id}-kas-db"
  description = "Security group for KAS PostgreSQL database (Kine backend)"
  vpc_id      = var.vpc_id

  # Prevent Terraform from trying to detach RDS-managed ENIs
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
      Name      = "${var.regional_id}-kas-db-sg"
      Component = "kas"
    }
  )
}

# Ingress rules as standalone resources — these depend on EKS SG IDs but
# do NOT block the RDS instance from provisioning.

resource "aws_security_group_rule" "kas_db_eks_cluster" {
  type                     = "ingress"
  description              = "PostgreSQL from EKS cluster additional security group"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.kas_db.id
  source_security_group_id = var.eks_cluster_security_group_id
}

resource "aws_security_group_rule" "kas_db_eks_primary" {
  type                     = "ingress"
  description              = "PostgreSQL from EKS cluster primary security group (Auto Mode)"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.kas_db.id
  source_security_group_id = var.eks_cluster_primary_security_group_id
}

resource "aws_security_group_rule" "kas_db_bastion" {
  count = var.bastion_enabled ? 1 : 0

  type                     = "ingress"
  description              = "PostgreSQL from bastion"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.kas_db.id
  source_security_group_id = var.bastion_security_group_id
}

# RDS PostgreSQL Instance
resource "aws_db_instance" "kas" {
  identifier = "${var.regional_id}-kas"

  # Engine configuration
  engine         = "postgres"
  engine_version = var.db_engine_version

  # Instance configuration
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  # Database configuration
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result
  port     = 5432

  # Network configuration
  db_subnet_group_name   = aws_db_subnet_group.kas.name
  vpc_security_group_ids = [aws_security_group.kas_db.id]
  publicly_accessible    = false

  # High availability
  multi_az = var.db_multi_az

  # Backup configuration
  backup_retention_period = var.db_backup_retention_period
  backup_window           = "03:00-04:00"         # 3-4 AM UTC
  maintenance_window      = "mon:04:00-mon:05:00" # Monday 4-5 AM UTC

  # Snapshot configuration
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_deletion_protection ? "${var.regional_id}-kas-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null
  deletion_protection       = var.db_deletion_protection

  # Monitoring and logging
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # days

  # Auto minor version upgrades
  auto_minor_version_upgrade = true

  # Parameter group - force SSL/TLS connections
  parameter_group_name = "default.postgres${var.db_engine_version}"

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-kas-db"
      Component = "kas"
    }
  )

  # Prevent replacement due to timestamp in final_snapshot_identifier
  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }

  depends_on = [
    aws_security_group.kas_db,
    aws_cloudwatch_log_group.rds_postgresql,
    aws_cloudwatch_log_group.rds_upgrade,
  ]
}
