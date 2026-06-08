# =============================================================================
# IAM Policies for ZOA
#
# Platform API policies attach to the existing role (owned by authz module).
# Job role is self-contained (runs on MCs with its own SA).
# =============================================================================

# =============================================================================
# Platform API - Additional policies on existing role
# =============================================================================

resource "aws_iam_role_policy" "platform_api_zoa_dynamodb" {
  name = "${var.regional_id}-zoa-dynamodb"
  role = var.platform_api_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
        ]
        Resource = [
          aws_dynamodb_table.executions.arn,
          "${aws_dynamodb_table.executions.arn}/index/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "platform_api_zoa_s3" {
  name = "${var.regional_id}-zoa-s3"
  role = var.platform_api_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.outputs.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.outputs.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "platform_api_zoa_kms" {
  name = "${var.regional_id}-zoa-kms"
  role = var.platform_api_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = aws_kms_key.zoa.arn
      },
    ]
  })
}

# =============================================================================
# Job Role - Self-contained for TA jobs running on MCs
# =============================================================================

resource "aws_iam_role" "job" {
  name        = "${var.regional_id}-zoa-job"
  description = "IAM role for ZOA Trusted Action jobs running on Management Clusters"

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
      Name = "${var.regional_id}-zoa-job-role"
    }
  )
}

resource "aws_iam_role_policy" "job_s3" {
  name = "${var.regional_id}-zoa-job-s3-upload"
  role = aws_iam_role.job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.outputs.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "job_kms" {
  name = "${var.regional_id}-zoa-job-kms"
  role = aws_iam_role.job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "kms:GenerateDataKey"
        Resource = aws_kms_key.zoa.arn
      },
    ]
  })
}

# Pod Identity association for ZOA jobs running on the RC itself.
# The RC is in the same account as this module so we can create it directly.
resource "aws_eks_pod_identity_association" "job_rc" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-kube-sa"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-job-rc-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "job_rc_aws_read" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-aws-read-sa"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-aws-read-rc-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "job_rc_aws_write" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-aws-write-sa"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-aws-write-rc-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "job_rc_breakglass_read" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-breakglass-read-sa"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-breakglass-read-rc-pod-identity"
  })
}

resource "aws_eks_pod_identity_association" "job_rc_breakglass_write" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-breakglass-write-sa"
  role_arn        = aws_iam_role.job.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-zoa-breakglass-write-rc-pod-identity"
  })
}

# NOTE: Pod Identity associations for ZOA jobs on MCs are created by the
# zoa-job-pod-identity module in the management-cluster Terraform config,
# because associations must be in the same AWS account as the EKS cluster.
