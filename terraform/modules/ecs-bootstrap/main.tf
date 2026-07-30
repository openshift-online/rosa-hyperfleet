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

          # Wait for coredns and metrics-server (on the bootstrap node group)
          # before installing Karpenter and ArgoCD.
          for ADDON in coredns metrics-server; do
            echo "Waiting for $ADDON to be active..."
            aws eks wait addon-active \
              --cluster-name "$CLUSTER_NAME" \
              --addon-name "$ADDON" \
              --region "$AWS_REGION"
            echo "✓ $ADDON active"
          done

          if [ -n "$${KARPENTER_CONTROLLER_ROLE_ARN:-}" ]; then
            # Install Karpenter before seeding the NodePool: the NodePool and
            # EC2NodeClass CRDs (karpenter.sh/v1, karpenter.k8s.aws/v1) don't
            # exist until Karpenter is installed. ArgoCD adopts this release
            # via its self-managed Karpenter Application after bootstrap.
            if ! helm status karpenter -n kube-system 2>/dev/null | grep -q "^STATUS: deployed"; then
              echo "Installing Karpenter $KARPENTER_VERSION..."
              if [ -z "$${KARPENTER_QUEUE_URL:-}" ]; then
                echo "ERROR: KARPENTER_QUEUE_URL is not set — required when KARPENTER_CONTROLLER_ROLE_ARN is provided" >&2
                exit 1
              fi
              _KARPENTER_QUEUE_NAME=$(basename "$KARPENTER_QUEUE_URL")
              helm upgrade --install karpenter \
                oci://public.ecr.aws/karpenter/karpenter \
                --version "$KARPENTER_VERSION" \
                --namespace kube-system \
                --set "settings.clusterName=$CLUSTER_NAME" \
                --set "settings.interruptionQueue=$_KARPENTER_QUEUE_NAME" \
                --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARPENTER_CONTROLLER_ROLE_ARN" \
                --set 'tolerations[0].key=CriticalAddonsOnly' \
                --set 'tolerations[0].operator=Exists' \
                --set 'tolerations[0].effect=NoSchedule' \
                --wait --timeout=5m
              echo "✓ Karpenter installed"
            else
              echo "✓ Karpenter already deployed, skipping"
            fi

            # Seed the FIPS NodePool only on first bootstrap. On subsequent
            # runs (resync), ArgoCD owns this resource via the eks-nodepool
            # chart — re-applying it creates SSA ownership conflicts.
            if ! kubectl get nodepool workloads 2>/dev/null; then
              echo "Applying FIPS EC2NodeClass and workloads NodePool from chart..."
              _NODEPOOL_VALUES="$REPO_DIR/deploy/$ENVIRONMENT/$REGION_DEPLOYMENT/argocd-values-$CLUSTER_TYPE.yaml"
              _VALUES_FLAG=""
              [ -f "$_NODEPOOL_VALUES" ] && _VALUES_FLAG="-f $_NODEPOOL_VALUES"
              helm template eks-nodepool "$REPO_DIR/argocd/config/$CLUSTER_TYPE/eks-nodepool" \
                --set global.cluster_name="$CLUSTER_NAME" \
                $_VALUES_FLAG \
                | kubectl apply --server-side -f -
              echo "✓ FIPS EC2NodeClass and NodePool applied"
            else
              echo "✓ FIPS NodePool already exists, skipping (managed by ArgoCD)"
            fi

          fi

          # If a previous bootstrap run failed mid-install, the Helm release is
          # left in 'failed' state. Running helm upgrade on a failed HA ArgoCD
          # install causes a StatefulSet rolling-update deadlock: redis-ha uses
          # OrderedReady policy, so pod-0 must be Ready before pod-1 is created,
          # but pod-0's Sentinel readiness probe requires quorum from pods 1 & 2.
          # Fix: uninstall the broken release so the next helm upgrade --install
          # does a clean initial install with all pods created from scratch.
          if helm status argocd -n argocd 2>/dev/null | grep -q "^STATUS: failed\|^STATUS: pending"; then
            echo "ArgoCD Helm release is in a broken state, uninstalling for clean reinstall..."
            if ! helm uninstall argocd -n argocd; then
              echo "ERROR: helm uninstall argocd failed — cannot recover from broken release" >&2
              helm status argocd -n argocd >&2 || true
              exit 1
            fi
            kubectl wait --for=delete pod --all -n argocd --timeout=120s 2>/dev/null || true
          fi

          echo "Installing/upgrading ArgoCD from repo chart..."

          # Create argocd namespace
          kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

          # Re-stamp Helm release ownership annotations before upgrade.
          # ArgoCD's default client-side apply strips meta.helm.sh/* annotations
          # because they are not part of chart templates: the 3-way merge removes
          # keys present in the last-applied-configuration but absent from the new
          # desired state. Without these annotations helm upgrade refuses to manage
          # the resource ("cannot be imported into the current release").
          # This is a no-op on fresh clusters where no resources exist yet.
          echo "Re-stamping Helm release ownership annotations on existing argocd resources..."
          for _RT in \
            deployments statefulsets services configmaps serviceaccounts \
            roles rolebindings secrets \
            poddisruptionbudgets horizontalpodautoscalers networkpolicies \
            servicemonitors prometheusrules podmonitors; do
            kubectl get "$_RT" -n argocd -o name 2>/dev/null | while read -r _RES; do
              kubectl annotate -n argocd "$_RES" \
                "meta.helm.sh/release-name=argocd" \
                "meta.helm.sh/release-namespace=argocd" \
                --overwrite || true
            done || true
          done

          # Fetch chart dependencies (charts/ is gitignored)
          helm repo add argo https://argoproj.github.io/argo-helm
          helm dependency build "$REPO_DIR/argocd/config/shared/argocd"

          # Install using the same chart that the self-managed ArgoCD app
          # uses (argocd/config/shared/argocd/), with tracking-id annotations
          # so the self-managed ArgoCD app can adopt these resources.
          # redisSecretInit is enabled here to create the Redis auth secret;
          # the self-managed ArgoCD app has it disabled and prunes the
          # completed Job on adoption.
          #
          # CriticalAddonsOnly tolerations are set both here (via --set, for
          # any git branch) and in values.yaml (for ArgoCD self-management).
          helm upgrade --install argocd "$REPO_DIR/argocd/config/shared/argocd" \
            --namespace argocd \
            --set argo-cd.redisSecretInit.enabled=true \
            --set 'argo-cd.redisSecretInit.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.redisSecretInit.tolerations[0].operator=Exists' \
            --set 'argo-cd.redisSecretInit.tolerations[0].effect=NoSchedule' \
            --set 'argo-cd.server.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.server.tolerations[0].operator=Exists' \
            --set 'argo-cd.server.tolerations[0].effect=NoSchedule' \
            --set 'argo-cd.controller.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.controller.tolerations[0].operator=Exists' \
            --set 'argo-cd.controller.tolerations[0].effect=NoSchedule' \
            --set 'argo-cd.repoServer.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.repoServer.tolerations[0].operator=Exists' \
            --set 'argo-cd.repoServer.tolerations[0].effect=NoSchedule' \
            --set 'argo-cd.applicationSet.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.applicationSet.tolerations[0].operator=Exists' \
            --set 'argo-cd.applicationSet.tolerations[0].effect=NoSchedule' \
            --set 'argo-cd.dex.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.dex.tolerations[0].operator=Exists' \
            --set 'argo-cd.dex.tolerations[0].effect=NoSchedule' \
            --set 'argo-cd.notifications.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.notifications.tolerations[0].operator=Exists' \
            --set 'argo-cd.notifications.tolerations[0].effect=NoSchedule' \
            --set 'argo-cd.redis-ha.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.redis-ha.tolerations[0].operator=Exists' \
            --set 'argo-cd.redis-ha.tolerations[0].effect=NoSchedule' \
            --set 'argo-cd.redis-ha.haproxy.tolerations[0].key=CriticalAddonsOnly' \
            --set 'argo-cd.redis-ha.haproxy.tolerations[0].operator=Exists' \
            --set 'argo-cd.redis-ha.haproxy.tolerations[0].effect=NoSchedule' \
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

          # For MC clusters, wait for hypershift to be Healthy before returning.
          # The E2E test starts immediately after bootstrap exits; HyperShift must
          # be fully installed before the work agent can apply HostedCluster manifests.
          if [ "$${CLUSTER_TYPE:-}" = "management-cluster" ]; then
            echo "=== Waiting for hypershift Application to be Healthy (up to 30m) ==="
            _HS_DEADLINE=$((SECONDS + 1800))
            until _HS_HEALTH=$(kubectl get application hypershift -n argocd \
                -o jsonpath='{.status.health.status}' 2>/tmp/hs-err) \
                && [ "$${_HS_HEALTH}" = "Healthy" ]; do
              if grep -qiE "unable to connect|connection refused|i/o timeout|no such host" /tmp/hs-err 2>/dev/null; then
                echo "ERROR: kubectl cannot reach the API server — cannot wait for hypershift:" >&2
                cat /tmp/hs-err >&2
                exit 1
              fi
              if [ $SECONDS -ge $_HS_DEADLINE ]; then
                echo "ERROR: hypershift Application not Healthy after 30 minutes" >&2
                kubectl get application hypershift -n argocd -o yaml 2>/dev/null || true
                exit 1
              fi
              _HS_STATUS=$(kubectl get application hypershift -n argocd \
                -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NotFound")
              _HS_MSG=$(kubectl get application hypershift -n argocd \
                -o jsonpath='{.status.health.message}' 2>/dev/null || true)
              echo "  hypershift health: $${_HS_STATUS} ($(( _HS_DEADLINE - SECONDS ))s remaining)$${_HS_MSG:+ — $${_HS_MSG}}"
              sleep 15
            done
            echo "=== hypershift is Healthy ==="
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
          name  = "KARPENTER_QUEUE_URL"
          value = var.karpenter_queue_url
        },
        {
          name  = "KARPENTER_VERSION"
          value = var.karpenter_version
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