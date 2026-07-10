# ECS Bootstrap Module for ArgoCD
# Provides ECS Fargate infrastructure for external bootstrap execution

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

# ECS Task Definition for bootstrap execution
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

          # Seed the FIPS NodePool only on first bootstrap. On subsequent
          # runs (resync), ArgoCD owns this resource via the eks-nodepool
          # chart — we must not re-apply it to avoid Server-Side Apply
          # ownership conflicts. When creating, we pass the environment
          # values file so the initial NodePool matches what ArgoCD will
          # enforce, avoiding Karpenter provisioning nodes with default
          # instance types before ArgoCD syncs.
          if ! kubectl get nodepool workloads 2>/dev/null; then
            echo "Applying FIPS NodeClass and workloads NodePool from chart..."
            _NODEPOOL_VALUES="$REPO_DIR/deploy/$ENVIRONMENT/$REGION_DEPLOYMENT/argocd-values-$CLUSTER_TYPE.yaml"
            _VALUES_FLAG=""
            [ -f "$_NODEPOOL_VALUES" ] && _VALUES_FLAG="-f $_NODEPOOL_VALUES"
            helm template eks-nodepool "$REPO_DIR/argocd/config/$CLUSTER_TYPE/eks-nodepool" \
              --set global.cluster_name="$CLUSTER_NAME" \
              $_VALUES_FLAG \
              | kubectl apply --server-side -f -
            echo "✓ FIPS NodePool applied"
          else
            echo "✓ FIPS NodePool already exists, skipping (managed by ArgoCD)"
          fi

          # Wait for coredns and metrics-server (managed by the built-in system pool)
          # to be active before installing ArgoCD.
          for ADDON in coredns metrics-server; do
            echo "Waiting for $ADDON to be active..."
            aws eks wait addon-active \
              --cluster-name "$CLUSTER_NAME" \
              --addon-name "$ADDON" \
              --region "$AWS_REGION"
            echo "✓ $ADDON active"
          done

          # Check if ArgoCD already exists
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
            helm upgrade --install argocd "$REPO_DIR/argocd/config/shared/argocd" \
              --namespace argocd \
              --set argo-cd.redisSecretInit.enabled=true \
              --set 'argo-cd.redisSecretInit.tolerations[0].key=CriticalAddonsOnly' \
              --set 'argo-cd.redisSecretInit.tolerations[0].operator=Exists' \
              --set 'argo-cd.redisSecretInit.tolerations[0].effect=NoSchedule' \
              --set-string 'argo-cd.controller.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --set-string 'argo-cd.server.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --set-string 'argo-cd.repoServer.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --wait --timeout=5m

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
              management_clusters: "$MANAGEMENT_CLUSTERS"
              rhobs_api_url: "$RHOBS_API_URL"
              dns_zone_operator_role_arn: "$DNS_ZONE_OPERATOR_ROLE_ARN"
              zoa_table_name: "$ZOA_TABLE_NAME"
              zoa_audit_table_name: "$ZOA_AUDIT_TABLE_NAME"
              zoa_bucket_name: "$ZOA_BUCKET_NAME"
              redis_endpoint: "$REDIS_ENDPOINT"
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

          echo "=== Bootstrap completed successfully ==="
        EOF
      ]

      essential = true

      environment = [
        {
          name  = "AWS_DEFAULT_REGION"
          value = data.aws_region.current.id
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
          name  = "REDIS_ENDPOINT"
          value = var.redis_endpoint
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bootstrap.name
          awslogs-region        = data.aws_region.current.id
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}