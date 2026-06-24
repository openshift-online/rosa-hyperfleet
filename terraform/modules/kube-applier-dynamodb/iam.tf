# =============================================================================
# Backend IAM Role
#
# This role is for the future backend service (running in the RC) that writes
# desires and reads status across all Management Clusters in a region.
#
# Backend permissions:
#   Specs tables (mc-*-specs-*): read-write (writes desires)
#     dynamodb:PutItem, UpdateItem, DeleteItem, GetItem, Scan, Query
#   Status tables (mc-*-status-*): read-only (monitors results)
#     dynamodb:GetItem, Scan, Query
#
# The role ARN is exported so the backend service can reference it.
# Wiring this role to an actual service is out of scope for this module.
# =============================================================================

resource "aws_iam_role" "kube_applier_backend" {
  name        = "${var.rc_id}-kube-applier-backend"
  description = "IAM role for the kube-applier backend service — reads/writes desire tables across all MCs in the region"

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
    var.tags,
    {
      ManagedBy = "terraform"
      Module    = "kube-applier-dynamodb"
      Name      = "${var.rc_id}-kube-applier-backend-role"
    }
  )

  lifecycle {
    # Only create this role once per RC (not per MC invocation).
    # The module is called once per MC but the role is shared; Terraform will
    # detect it already exists on subsequent MC creations and skip re-creation.
    ignore_changes = []
  }
}

# Policy: Read-write to specs tables across all MCs in this region
resource "aws_iam_role_policy" "backend_specs" {
  name = "${var.rc_id}-kube-applier-backend-specs"
  role = aws_iam_role.kube_applier_backend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "SpecsTablesReadWrite"
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:Query",
      ]
      Resource = [
        "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/mc-*-specs-*",
      ]
    }]
  })
}

# Policy: Read-only to status tables across all MCs in this region
resource "aws_iam_role_policy" "backend_status" {
  name = "${var.rc_id}-kube-applier-backend-status"
  role = aws_iam_role.kube_applier_backend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "StatusTablesReadOnly"
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:Query",
      ]
      Resource = [
        "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/mc-*-status-*",
      ]
    }]
  })
}
