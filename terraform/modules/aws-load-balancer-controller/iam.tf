# =============================================================================
# AWS Load Balancer Controller IAM Role and Policies
#
# IAM policy derived from the upstream recommended policy:
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.17.1/docs/install/iam_policy.json
# =============================================================================

resource "aws_iam_role" "aws_lbc" {
  name        = "${var.cluster_name}-aws-load-balancer-controller"
  description = "IAM role for AWS Load Balancer Controller (provides TargetGroupBinding CRDs)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-aws-load-balancer-controller"
    }
  )
}

resource "aws_iam_role_policy" "aws_lbc" {
  #checkov:skip=CKV_AWS_355: Describe-only APIs (EC2, ELB, ACM, etc.) do not support resource-level ARN restrictions; Resource="*" matches the upstream AWS Load Balancer Controller recommended policy.
  #checkov:skip=CKV_AWS_290: iam:CreateServiceLinkedRole requires Resource="*" per AWS; the statement is already constrained by a Condition on iam:AWSServiceName=elasticloadbalancing.amazonaws.com.
  name = "${var.cluster_name}-aws-load-balancer-controller"
  role = aws_iam_role.aws_lbc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CreateServiceLinkedRole"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Sid    = "EC2Read"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "ec2:GetSecurityGroupsForVpc",
          "ec2:DescribeIpamPools",
          "ec2:DescribeRouteTables",
        ]
        Resource = "*"
      },
      {
        Sid    = "ELBRead"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeCapacityReservation",
        ]
        Resource = "*"
      },
      {
        Sid      = "CognitoRead"
        Effect   = "Allow"
        Action   = ["cognito-idp:DescribeUserPoolClient"]
        Resource = "*"
      },
      {
        Sid    = "ACMRead"
        Effect = "Allow"
        Action = [
          "acm:ListCertificates",
          "acm:DescribeCertificate",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAMRead"
        Effect = "Allow"
        Action = [
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
        ]
        Resource = "*"
      },
      {
        Sid    = "WAFRead"
        Effect = "Allow"
        Action = [
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
        ]
        Resource = "*"
      },
      {
        Sid    = "WAFv2"
        Effect = "Allow"
        Action = [
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
        ]
        Resource = "*"
      },
      {
        Sid    = "ShieldRead"
        Effect = "Allow"
        Action = [
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2Mutate"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
        ]
        Resource = "*"
      },
      {
        Sid      = "EC2CreateSecurityGroup"
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Sid      = "EC2CreateTags"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSecurityGroup"
          }
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "EC2MutateTags"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid      = "EC2DeleteSecurityGroup"
        Effect   = "Allow"
        Action   = ["ec2:DeleteSecurityGroup"]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "ELBCreateTagged"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "ELBCreateListenerAndRule"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
        ]
        Resource = "*"
      },
      {
        Sid    = "ELBMutateTags"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:loadbalancer/app/*/*",
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "ELBMutateListenerRuleTags"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
        ]
      },
      {
        Sid    = "ELBMutateTagged"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyListenerAttributes",
          "elasticloadbalancing:ModifyCapacityReservation",
          "elasticloadbalancing:ModifyIpPools",
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "ELBAddListenerCert"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:SetRulePriorities",
        ]
        Resource = "*"
      },
      {
        Sid    = "ELBTargets"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Sid    = "ELBMutateAttributes"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "aws_lbc" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.aws_lbc.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-aws-load-balancer-controller-pod-identity"
    }
  )
}
