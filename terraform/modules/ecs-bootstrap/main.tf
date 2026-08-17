# =============================================================================
# ECS Bootstrap Module for ArgoCD
#
# IMPORTANT: This module provides the INSTALLATION MECHANISM for ArgoCD in
# fully private EKS clusters. It does NOT host the runtime workloads, and it
# does NOT install Karpenter — ArgoCD installs Karpenter via GitOps after
# bootstrap completes (see the root Application created below).
#
# The Problem: Terraform can provision EKS clusters but cannot reach fully
# private cluster APIs to install software via the helm provider.
#
# The Solution: ECS Fargate tasks run in the cluster's VPC with network access
# to the private EKS API. A one-time bootstrap task performs `helm install` of
# ArgoCD onto the karpenter-bootstrap managed node group (defined in the
# eks-cluster module), then creates the root ArgoCD Application, which ArgoCD
# uses to install Karpenter and everything else. After installation completes,
# the ECS task exits.
#
# Runtime: Karpenter and ArgoCD run on the karpenter-bootstrap node group
# (2× m7i.xlarge with CriticalAddonsOnly taint) for the lifetime of the cluster.
#
# See docs/design/fully-private-eks-bootstrap.md for the full architecture and
# rationale for choosing ECS over alternatives (public→private transition, node
# group user data scripts, etc.).
# =============================================================================

locals {
  bootstrap_container_name = "bootstrap"
  log_retention_days       = 365
}

# Current AWS region information
data "aws_region" "current" {}

# ECS Cluster for bootstrap tasks
resource "aws_ecs_cluster" "bootstrap" {
  name = "${var.cluster_id}-bootstrap"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# KMS key for CloudWatch log group encryption (FedRAMP AU-09)
resource "aws_kms_key" "bootstrap_logs" {
  description             = "KMS key for ECS bootstrap CloudWatch log group encryption (FedRAMP AU-09)"
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
      }
    ]
  })

  tags = {
    Name = "${var.cluster_id}-bootstrap-logs"
  }
}

# CloudWatch Log Group for bootstrap tasks
resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/ecs/${var.cluster_id}/bootstrap"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.bootstrap_logs.arn

  depends_on = [aws_kms_key.bootstrap_logs]
}

# -----------------------------------------------------------------------------
# ECS Task Definition for Bootstrap Execution
#
# This task definition runs a one-time container that:
# 1. Connects to the private EKS cluster API (via VPC networking)
# 2. Installs ArgoCD (helm install) onto karpenter-bootstrap nodes
# 3. Creates the root ArgoCD Application for GitOps self-management —
#    ArgoCD then installs Karpenter (and everything else) via this Application
# 4. Exits
#
# After this task completes, Karpenter and ArgoCD continue running on the
# karpenter-bootstrap managed node group. This task is NOT the runtime - it's
# the installer. The ECS infrastructure remains available for future audited
# SRE operations (resync, break-glass access, disaster recovery).
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "bootstrap" {
  family                   = "${var.cluster_id}-bootstrap"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name  = local.bootstrap_container_name
      image = var.container_image

      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail

          echo "=== ArgoCD Bootstrap ==="
          echo "Tools: aws=$(aws --version 2>&1 | head -1), kubectl=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion'), helm=$(helm version --short), git=$(git --version)"

          # Clone the platform repo so bootstrap uses the same charts that
          # ArgoCD will manage, eliminating drift between bootstrap and
          # steady-state configuration.
          REPO_DIR=/tmp/repo
          echo "Cloning $REPOSITORY_URL @ $REPOSITORY_BRANCH..."
          git clone --depth 1 -b "$REPOSITORY_BRANCH" "$REPOSITORY_URL" "$REPO_DIR"
          echo "✓ Repository cloned"

          # Configure kubectl for EKS
          aws eks update-kubeconfig --name $CLUSTER_NAME

          # Wait for essential addons on the bootstrap node group before
          # installing ArgoCD. Pod Identity agent must be active so that
          # workloads deployed by ArgoCD (LBC, EBS CSI) can authenticate.
          for ADDON in coredns metrics-server eks-pod-identity-agent; do
            echo "Waiting for $ADDON to be active..."
            aws eks wait addon-active \
              --cluster-name "$CLUSTER_NAME" \
              --addon-name "$ADDON" \
              --region "$AWS_REGION"
            echo "✓ $ADDON active"
          done

          if ! kubectl get deployment argocd-server -n argocd 2>/dev/null; then
            echo "Installing ArgoCD from repo chart..."

            # Create argocd namespace
            kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

            # Fetch chart dependencies (charts/ is gitignored)
            helm repo add argo https://argoproj.github.io/argo-helm
            helm dependency build "$REPO_DIR/argocd/config/shared/argocd"

            # Install using the same chart that the self-managed ArgoCD app
            # uses (argocd/config/shared/argocd/), with tracking-id annotations
            # so the self-managed ArgoCD app can adopt these resources.
            # redisSecretInit is enabled here to create the Redis auth secret;
            # the self-managed ArgoCD app has it disabled and prunes the
            # completed Job on adoption.
            # CriticalAddonsOnly tolerations are defined in values.yaml and
            # picked up automatically by helm install — no --set flags needed.
            helm upgrade --install argocd "$REPO_DIR/argocd/config/shared/argocd" \
              --namespace argocd \
              --set argo-cd.redisSecretInit.enabled=true \
              --set 'argo-cd.redisSecretInit.tolerations[0].key=CriticalAddonsOnly' \
              --set 'argo-cd.redisSecretInit.tolerations[0].operator=Exists' \
              --set 'argo-cd.redisSecretInit.tolerations[0].effect=NoSchedule' \
              --set-string 'argo-cd.controller.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --set-string 'argo-cd.server.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --set-string 'argo-cd.repoServer.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --wait --timeout=10m

            echo "✓ ArgoCD installation complete"

            # Wait for ArgoCD to be ready
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-repo-server -n argocd
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-applicationset-controller -n argocd

            echo "✓ ArgoCD is running and ready"
          else
            echo "✓ ArgoCD is already installed and running, skipping installation"
          fi

          echo "Creating/updating cluster identity secret with values:"
          echo "  ENVIRONMENT: $ENVIRONMENT"
          echo "  AWS_REGION: $AWS_REGION"
          echo "  REGION_DEPLOYMENT: $REGION_DEPLOYMENT"
          echo "  CLUSTER_NAME: $CLUSTER_NAME"
          echo "  CLUSTER_TYPE: $CLUSTER_TYPE"
          echo "  REPOSITORY_URL: $REPOSITORY_URL"
          echo "  REPOSITORY_BRANCH: $REPOSITORY_BRANCH"
          echo "  DNS_ZONE_OPERATOR_ROLE_ARN: $DNS_ZONE_OPERATOR_ROLE_ARN"

          cat <<-SECRET_EOF | kubectl apply -f -
          apiVersion: v1
          kind: Secret
          metadata:
            name: local-cluster-identity
            namespace: argocd
            labels:
              argocd.argoproj.io/secret-type: cluster
              environment: "$ENVIRONMENT"
              region_deployment: "$REGION_DEPLOYMENT"
              aws_region: "$AWS_REGION"
              cluster_type: "$CLUSTER_TYPE"
              cluster_name: "$CLUSTER_NAME"
            annotations:
              git_repo: "$REPOSITORY_URL"
              git_revision: "$REPOSITORY_BRANCH"
              api_target_group_arn: "$API_TARGET_GROUP_ARN"
              dynamodb_prefix: "$CLUSTER_NAME"
              dynamodb_region: "$AWS_REGION"
              thanos_kms_key_arn: "$THANOS_KMS_KEY_ARN"
              thanos_target_group_arn: "$THANOS_TARGET_GROUP_ARN"
              thanos_query_target_group_arn: "$THANOS_QUERY_TARGET_GROUP_ARN"
              loki_kms_key_arn: "$LOKI_KMS_KEY_ARN"
              loki_distributor_target_group_arn: "$LOKI_DISTRIBUTOR_TARGET_GROUP_ARN"
              loki_query_frontend_target_group_arn: "$LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN"
              aws_account_id: "$AWS_ACCOUNT_ID"
              rc_aws_account_id: "$RC_AWS_ACCOUNT_ID"
              management_clusters: "$MANAGEMENT_CLUSTERS"
              rhobs_api_url: "$RHOBS_API_URL"
              dns_zone_operator_role_arn: "$DNS_ZONE_OPERATOR_ROLE_ARN"
              zoa_table_name: "$ZOA_TABLE_NAME"
              zoa_audit_table_name: "$ZOA_AUDIT_TABLE_NAME"
              zoa_bucket_name: "$ZOA_BUCKET_NAME"
              oidc_cloudfront_domain: "$OIDC_CLOUDFRONT_DOMAIN"
              sre_grafana_target_group_arn: "$SRE_GRAFANA_TARGET_GROUP_ARN"
              sre_argocd_target_group_arn: "$SRE_ARGOCD_TARGET_GROUP_ARN"
              sre_prometheus_target_group_arn: "$SRE_PROMETHEUS_TARGET_GROUP_ARN"
              sre_thanos_target_group_arn: "$SRE_THANOS_TARGET_GROUP_ARN"
              sre_alb_dns_name: "$SRE_ALB_DNS_NAME"
              sre_domain: "$SRE_DOMAIN"
              redis_endpoint: "$REDIS_ENDPOINT"
              karpenter_controller_role_arn: "$KARPENTER_CONTROLLER_ROLE_ARN"
              vpc_id: "$VPC_ID"
          type: Opaque
          stringData:
            name: in-cluster
            server: https://kubernetes.default.svc
            config: |
              {
                "tlsClientConfig": { "insecure": false }
              }
          SECRET_EOF

          echo "Creating/updating ArgoCD Root Application..."
          echo "  Repository URL: $REPOSITORY_URL"
          echo "  Target Revision: $REPOSITORY_BRANCH"
          echo "  Target Path: $REPOSITORY_PATH"
          
          cat <<-APP_EOF | kubectl apply -f -
          apiVersion: argoproj.io/v1alpha1
          kind: Application
          metadata:
            name: root
            namespace: argocd
          spec:
            destination:
              namespace: argocd
              server: https://kubernetes.default.svc
            project: default
            source:
              repoURL: $REPOSITORY_URL
              targetRevision: $REPOSITORY_BRANCH
              path: $REPOSITORY_PATH
            syncPolicy:
              automated:
                prune: false
                selfHeal: true
              syncOptions:
                - CreateNamespace=true
          APP_EOF

          # ArgoCD will install Karpenter and create the NodePool via Applications.
          # No ECS seeding needed - Applications sync concurrently (no sync-wave
          # ordering) and retry with backoff until eks-nodepool's NodePool/
          # EC2NodeClass apply succeeds once Karpenter's CRDs are registered.

          # CI: E2E test runner starts immediately after bootstrap exits, so
          # HyperShift must be fully installed before work agents apply
          # HostedCluster manifests. This wait is a CI accommodation — bootstrap
          # has no production requirement to block on application-level health.
          # WAIT_FOR_HYPERSHIFT_HEALTH must be set to "true" by the E2E workflow
          # invocation (e.g. via bootstrap-argocd.sh); ordinary bootstraps leave
          # it unset and skip this wait entirely.
          if [ "$${CLUSTER_TYPE:-}" = "management-cluster" ] && [ "$${WAIT_FOR_HYPERSHIFT_HEALTH:-false}" = "true" ]; then
            echo "=== Waiting for hypershift Application to be Synced and Healthy (up to 30m) ==="
            _HS_DEADLINE=$((SECONDS + 1800))
            until _HS_STATE=$(kubectl get application hypershift -n argocd --request-timeout=10s \
                -o jsonpath='{.status.sync.status}|{.status.health.status}' 2>/tmp/hs-err) \
                && [ "$${_HS_STATE}" = "Synced|Healthy" ]; do
              if grep -qiE "unable to connect|connection refused|i/o timeout|no such host" /tmp/hs-err 2>/dev/null; then
                echo "ERROR: kubectl cannot reach the API server — cannot wait for hypershift:" >&2
                cat /tmp/hs-err >&2
                exit 1
              fi
              if [ $SECONDS -ge $_HS_DEADLINE ]; then
                echo "ERROR: hypershift Application not Synced and Healthy after 30 minutes" >&2
                kubectl get application hypershift -n argocd --request-timeout=10s -o yaml 2>/dev/null || true
                exit 1
              fi
              _HS_SYNC=$(kubectl get application hypershift -n argocd --request-timeout=10s \
                -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
              _HS_HEALTH=$(kubectl get application hypershift -n argocd --request-timeout=10s \
                -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NotFound")
              _HS_MSG=$(kubectl get application hypershift -n argocd --request-timeout=10s \
                -o jsonpath='{.status.health.message}' 2>/dev/null || true)
              echo "  hypershift sync: $${_HS_SYNC}, health: $${_HS_HEALTH} ($(( _HS_DEADLINE - SECONDS ))s remaining)$${_HS_MSG:+ — $${_HS_MSG}}"
              sleep 15
            done
            echo "=== hypershift is Synced and Healthy ==="
          fi

          echo "=== Bootstrap completed successfully ==="
        EOF
      ]

      essential = true

      environment = [
        {
          name  = "AWS_DEFAULT_REGION"
          value = data.aws_region.current.name
        },
        {
          name  = "THANOS_KMS_KEY_ARN"
          value = var.thanos_kms_key_arn
        },
        {
          name  = "LOKI_KMS_KEY_ARN"
          value = var.loki_kms_key_arn
        },
        {
          name  = "AWS_ACCOUNT_ID"
          value = data.aws_caller_identity.current.account_id
        },
        {
          name  = "MANAGEMENT_CLUSTERS"
          value = var.management_clusters
        },
        {
          name  = "RC_AWS_ACCOUNT_ID"
          value = var.rc_aws_account_id
        },
        {
          name  = "REDIS_ENDPOINT"
          value = var.redis_endpoint
        },
        {
          name  = "KARPENTER_CONTROLLER_ROLE_ARN"
          value = var.karpenter_controller_role_arn
        },
        {
          name  = "VPC_ID"
          value = var.vpc_id
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bootstrap.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}