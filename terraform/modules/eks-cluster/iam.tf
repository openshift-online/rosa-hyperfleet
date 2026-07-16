# =============================================================================
# IAM Roles and Policies for EKS Cluster
#
# Supports two compute modes, selected by var.enable_karpenter:
#
#   false — EKS Auto Mode
#     - eks_cluster role: AmazonEKSClusterPolicy + all four Auto Mode policies
#     - eks_auto_mode_node role: AmazonEKSWorkerNodeMinimalPolicy + ECR pull-only
#
#   true (default) — OSS Karpenter
#     - eks_cluster role: AmazonEKSClusterPolicy only (Auto Mode policies removed)
#     - eks_auto_mode_node role: exists but has no policy attachments (unused)
#     - karpenter_node role: full AmazonEKSWorkerNodePolicy + CNI + ECR + SSM
#     - karpenter_controller role: IRSA-backed, scoped to kube-system/karpenter SA
#     - ebs_csi role: Pod Identity-backed, scoped to kube-system/ebs-csi-controller-sa
#     - SQS interruption queue + four EventBridge rules
# =============================================================================

# -----------------------------------------------------------------------------
# EKS Cluster Service Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_id}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_managed" {
  for_each = toset(concat(
    ["arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"],
    var.enable_karpenter ? [] : [
      "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSComputePolicy",
      "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSBlockStoragePolicy",
      "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
      "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSNetworkingPolicy",
    ]
  ))
  policy_arn = each.value
  role       = aws_iam_role.eks_cluster.name
}

# -----------------------------------------------------------------------------
# EKS Auto Mode Node Role
#
# Always created so that existing Auto Mode clusters can reference it in
# compute_config without requiring a count-indexed reference. When
# enable_karpenter = true the policy attachments are empty and the cluster's
# compute_config dynamic block is absent, so this role is unused but harmless.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eks_auto_mode_node" {
  name = "${local.cluster_id}-auto-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = ["sts:AssumeRole", "sts:TagSession"]
      Effect = "Allow"
      Principal = {
        Service = ["ec2.amazonaws.com", "eks.amazonaws.com"]
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "auto_node_managed" {
  for_each = var.enable_karpenter ? toset([]) : toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_auto_mode_node.name
}

# =============================================================================
# Karpenter — all resources below are gated on var.enable_karpenter
# =============================================================================

# -----------------------------------------------------------------------------
# Karpenter Node Role + Instance Profile
#
# Used by both Karpenter-provisioned FIPS nodes (via EC2NodeClass.spec.instanceProfile)
# and the AL2023 bootstrap managed node group.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "karpenter_node" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.cluster_id}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_managed" {
  for_each = var.enable_karpenter ? toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]) : toset([])
  policy_arn = each.value
  role       = aws_iam_role.karpenter_node[0].name
}

# Instance profile wrapping the node role. Referenced by EC2NodeClass.spec.instanceProfile.
# Pre-creating it here avoids race conditions during bootstrap and removes the
# need for iam:CreateInstanceProfile in the Karpenter controller policy.
resource "aws_iam_instance_profile" "karpenter_node" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.cluster_id}-karpenter-node-role"
  role  = aws_iam_role.karpenter_node[0].name
}

# -----------------------------------------------------------------------------
# OIDC Provider — required for Karpenter controller IRSA
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "eks" {
  count           = var.enable_karpenter ? 1 : 0
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc[0].certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# -----------------------------------------------------------------------------
# Karpenter Controller Role (IRSA)
#
# Karpenter predates EKS Pod Identity support; IRSA is the supported auth
# mechanism. See ADR docs/design/karpenter-node-provisioning.md.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.cluster_id}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:karpenter"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0
  name  = "karpenter-controller"
  role  = aws_iam_role.karpenter_controller[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2FleetDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2FleetCreate"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:RunInstances",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.cluster_id}" = "owned"
          }
        }
      },
      {
        # The nodeclaim.tagging controller calls CreateTags on already-running instances
        # to apply karpenter.sh/* labels post-creation. aws:RequestTag only applies to
        # tags set during resource creation, so a separate statement scoped by
        # aws:ResourceTag is required for post-creation tagging.
        Sid    = "EC2NodeClaimTagging"
        Effect = "Allow"
        Action = ["ec2:CreateTags"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:*:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:network-interface/*",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_id}" = "owned"
          }
        }
      },
      {
        # RunInstances on pre-existing resources (AMI, security-group, subnet) must be
        # unconditional: these resources don't receive aws:RequestTag during RunInstances,
        # so the RequestTag condition in EC2FleetCreate always denies them. This is the
        # same split used in the official Karpenter IAM policy.
        Sid    = "EC2RunInstancesValidation"
        Effect = "Allow"
        Action = ["ec2:RunInstances"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:*::image/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:security-group/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:spot-instances-request/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:subnet/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:volume/*",
        ]
      },
      {
        Sid    = "EC2FleetDelete"
        Effect = "Allow"
        Action = [
          "ec2:DeleteLaunchTemplate",
          "ec2:TerminateInstances",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_id}" = "owned"
          }
        }
      },
      {
        Sid    = "IAMInstanceProfileCreate"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.cluster_id}" = "owned"
          }
        }
      },
      {
        Sid    = "IAMInstanceProfileModify"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_id}" = "owned"
          }
        }
      },
      {
        # GetInstanceProfile and ListInstanceProfiles are read-only and must be
        # unconditional: Karpenter calls GetInstanceProfile before creating (and
        # tagging) a profile, so a ResourceTag condition always denies it.
        # ListInstanceProfiles is required by the instance-profile GC controller.
        Sid    = "IAMInstanceProfileRead"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:ListInstanceProfiles",
        ]
        Resource = "*"
      },
      {
        Sid      = "IAMPassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node[0].arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid    = "SQS"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
        Resource = aws_sqs_queue.karpenter_interruption[0].arn
      },
      {
        Sid      = "EKS"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = aws_eks_cluster.main.arn
      },
      {
        Sid      = "SSM"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:*:*:parameter/aws/service/*"
      },
      {
        Sid      = "Pricing"
        Effect   = "Allow"
        Action   = "pricing:GetProducts"
        Resource = "*"
      },
    ]
  })
}

# The controller (IRSA) calls RunInstances, which requires kms:CreateGrant so
# EC2 can decrypt the RHEL FIPS AMI's encrypted EBS snapshot on instance launch.
# kms:GrantIsForAWSResource restricts grant creation to AWS service principals,
# preventing the controller from granting arbitrary IAM principals key access.
resource "aws_iam_role_policy" "karpenter_controller_kms" {
  count = var.enable_karpenter && var.ami_kms_key_arn != "" ? 1 : 0
  name  = "rhel-ami-kms"
  role  = aws_iam_role.karpenter_controller[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RhelAmiKmsGrant"
        Effect   = "Allow"
        Action   = ["kms:CreateGrant"]
        Resource = var.ami_kms_key_arn
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      },
      {
        Sid      = "RhelAmiKmsDescribe"
        Effect   = "Allow"
        Action   = ["kms:DescribeKey"]
        Resource = var.ami_kms_key_arn
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# SQS Interruption Queue + EventBridge Rules
#
# Receives EC2 Spot, rebalance, state-change, and AWS Health events so Karpenter
# can drain nodes before the 2-minute Spot termination window expires.
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "karpenter_interruption" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.cluster_id}-karpenter"

  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  count     = var.enable_karpenter ? 1 : 0
  queue_url = aws_sqs_queue.karpenter_interruption[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridge"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption[0].arn
    }]
  })
}

locals {
  karpenter_event_rules = var.enable_karpenter ? {
    spot-interruption = {
      description   = "Karpenter: EC2 Spot Instance Interruption Warning"
      event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Spot Instance Interruption Warning"] })
    }
    instance-terminated = {
      description   = "Karpenter: EC2 Instance Terminated"
      event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Instance State-change Notification"], detail = { state = ["terminated"] } })
    }
    rebalance-recommendation = {
      description   = "Karpenter: EC2 Instance Rebalance Recommendation"
      event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Instance Rebalance Recommendation"] })
    }
    health-scheduled-change = {
      description   = "Karpenter: AWS Health EC2 Scheduled Change"
      event_pattern = jsonencode({ source = ["aws.health"], "detail-type" = ["AWS Health Event"], detail = { service = ["EC2"], eventTypeCategory = ["scheduledChange"] } })
    }
  } : {}
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each      = local.karpenter_event_rules
  name          = "${local.cluster_id}-karpenter-${each.key}"
  description   = each.value.description
  event_pattern = each.value.event_pattern
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each = local.karpenter_event_rules
  rule     = aws_cloudwatch_event_rule.karpenter[each.key].name
  arn      = aws_sqs_queue.karpenter_interruption[0].arn
}

# -----------------------------------------------------------------------------
# EBS CSI Driver Role (Pod Identity)
#
# Pod Identity is the platform-standard auth mechanism for addons. The controller
# service account (ebs-csi-controller-sa in kube-system) is bound via
# aws_eks_pod_identity_association — no service_account_role_arn annotation needed.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ebs_csi" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.cluster_id}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.enable_karpenter ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi[0].name
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  count           = var.enable_karpenter ? 1 : 0
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi[0].arn
}
