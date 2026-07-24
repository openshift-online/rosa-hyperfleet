# =============================================================================
# EKS Cluster Configuration
#
# Creates a fully private EKS cluster with OSS Karpenter compute.
# Includes KMS encryption for secrets, proper networking,
# and managed addons for a complete cluster deployment.
# VPC and networking are provided as inputs from the vpc module.
# =============================================================================

# -----------------------------------------------------------------------------
# FedRAMP AU-09: KMS Key for Audit Log Encryption
#
# Customer-managed KMS key encrypts EKS CloudWatch log data at rest so that
# audit records cannot be read without KMS key authorization. Note: KMS does
# not prevent deletion — log group deletion and retention are controlled by
# IAM permissions (logs:DeleteLogGroup) and the retention_in_days setting.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "cloudwatch_logs" {
  description             = "KMS key for EKS cluster CloudWatch log group encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.cluster_id}/cluster"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${local.cluster_id}-cloudwatch-logs"
  }
}

resource "aws_kms_alias" "cloudwatch_logs" {
  name          = "alias/${local.cluster_id}-cloudwatch-logs"
  target_key_id = aws_kms_key.cloudwatch_logs.key_id
}

# -----------------------------------------------------------------------------
# CloudWatch Logging
# -----------------------------------------------------------------------------

# Note: setting kms_key_id on an existing log group only encrypts newly ingested
# events. Historical events remain under the previously configured key (or no key).
# For brownfield clusters, export historical logs to S3 before applying this change,
# or document a compliance exception. Do NOT delete/recreate the log group as this
# would discard retained audit logs required by AU-11.
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.cluster_id}/cluster"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.cloudwatch_logs.arn

  depends_on = [aws_kms_key.cloudwatch_logs]
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = local.cluster_id
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [var.cluster_security_group_id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_managed,
    aws_cloudwatch_log_group.eks_cluster,
    aws_kms_key.eks_secrets
  ]

  # Terminate Karpenter-provisioned EC2 instances before the cluster is deleted.
  # Karpenter nodes are not in Terraform state, so they survive EKS deletion and
  # block VPC/subnet teardown with DependencyViolation due to lingering ENIs.
  # on_failure = continue so a missing AWS CLI or zero instances doesn't abort destroy.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      CLUSTER_NAME="${self.name}"
      REGION=$(echo "${self.arn}" | cut -d: -f4)
      echo "Terminating Karpenter EC2 instances for cluster: $CLUSTER_NAME"
      INSTANCE_IDS=$(aws ec2 describe-instances \
        --region "$REGION" \
        --filters \
          "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" \
          "Name=tag-key,Values=karpenter.sh/nodeclaim" \
          "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
      if [ -z "$INSTANCE_IDS" ]; then
        echo "No Karpenter-managed instances found."
        exit 0
      fi
      echo "Terminating: $INSTANCE_IDS"
      aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS
      aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS
      echo "Done."
    EOT
  }
}

# -----------------------------------------------------------------------------
# EKS Managed Addons
#
# Essential addons for cluster functionality:
# - CoreDNS: cluster DNS resolution
# - metrics-server: pod/node metrics for HPA and kubectl top
# - Pod Identity Agent: AWS IAM integration for workloads (DaemonSet, safe pre-node)
# - AWS Secrets Store CSI Driver Provider: Secret mounting (DaemonSet, safe pre-node)
#
# CoreDNS and metrics-server are declared here so Terraform creates them before
# the ECS bootstrap task runs. The built-in "system" pool provides nodes for them
# to schedule on, so there is no deadlock. Without this declaration, a fresh cluster
# has no coredns/metrics-server addons and the bootstrap wait-addon-active call fails
# with ResourceNotFoundException.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "metrics-server"
  depends_on   = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
  depends_on   = [aws_eks_node_group.karpenter_bootstrap]
}

# -----------------------------------------------------------------------------
# Karpenter Bootstrap Node Group
#
# AL2023 managed node group (t3.medium × 2, CriticalAddonsOnly:NoSchedule) that
# provides fixed capacity for the Karpenter controller and VPC CNI daemonset
# before any Karpenter-provisioned nodes exist. This breaks the bootstrap
# deadlock: Karpenter cannot provision nodes for itself.
#
# No custom launch template: EKS managed node groups set IMDSv2 hop limit to 2
# by default for AL2023, and managed node group auth is handled automatically
# by EKS regardless of node name format.
# -----------------------------------------------------------------------------

resource "aws_eks_node_group" "karpenter_bootstrap" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_id}-karpenter-bootstrap"
  node_role_arn   = aws_iam_role.karpenter_node.arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = {
    "karpenter.sh/discovery" = aws_eks_cluster.main.name
  }

  depends_on = [
    aws_iam_role_policy_attachment.karpenter_node_managed,
    aws_eks_addon.vpc_cni,
  ]
}

# -----------------------------------------------------------------------------
# Explicit Core Addons (Karpenter mode only)
#
# bootstrap_self_managed_addons = false prevents EKS from auto-installing these.
# Auto Mode clusters receive VPC CNI and kube-proxy from the managed control
# plane; Karpenter clusters must declare them explicitly.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  depends_on = [aws_eks_node_group.karpenter_bootstrap, aws_eks_pod_identity_association.ebs_csi]
}

# AWS Secrets Store CSI Driver Provider (e.g. for Maestro agent secret mounting)
resource "aws_eks_addon" "aws_secrets_store_csi_driver_provider" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-secrets-store-csi-driver-provider"

  configuration_values = jsonencode({
    secrets-store-csi-driver = {
      syncSecret = {
        enabled = true
      }
    }
  })

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}
