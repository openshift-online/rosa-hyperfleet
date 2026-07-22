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
            _KARPENTER_READY=$(kubectl get deployment karpenter -n kube-system \
              -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
            if [ -z "$_KARPENTER_READY" ] || [ "$_KARPENTER_READY" -lt 1 ]; then
              echo "Installing Karpenter $KARPENTER_VERSION..."
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
              echo "✓ Karpenter ready (readyReplicas=$_KARPENTER_READY), skipping"
            fi

            # Always apply the EC2NodeClass and NodePool from the current chart.
            # kubectl apply --server-side is idempotent — it patches in-place.
            # The original skip-if-exists guard caused a bootstrap bug: the first
            # run seeded the EC2NodeClass with the wrong IAM role name, and all
            # subsequent runs silently kept the broken spec, so Karpenter could
            # never provision nodes. ArgoCD eventually owns these resources, but
            # we must ensure the correct spec is present before ArgoCD is up.
            echo "Applying FIPS EC2NodeClass and workloads NodePool from chart..."
            _NODEPOOL_VALUES="$REPO_DIR/deploy/$ENVIRONMENT/$REGION_DEPLOYMENT/argocd-values-$CLUSTER_TYPE.yaml"
            _VALUES_FLAG=""
            [ -f "$_NODEPOOL_VALUES" ] && _VALUES_FLAG="-f $_NODEPOOL_VALUES"
            helm template eks-nodepool "$REPO_DIR/argocd/config/$CLUSTER_TYPE/eks-nodepool" \
              --set global.cluster_name="$CLUSTER_NAME" \
              $_VALUES_FLAG \
              | kubectl apply --server-side -f -
            echo "✓ FIPS EC2NodeClass and NodePool applied"

            # Pre-warm: provision one node now so EC2 API rate limiting from
            # Terraform surfaces as an ECS task failure (with automatic retry)
            # rather than a silent cascade after ArgoCD is installed.
            echo "Pre-warming Karpenter: provisioning one node before ArgoCD install..."
            kubectl delete pod karpenter-prewarm -n kube-system --ignore-not-found=true
            kubectl apply -f - <<-PREWARM_EOF
            apiVersion: v1
            kind: Pod
            metadata:
              name: karpenter-prewarm
              namespace: kube-system
              labels:
                app: karpenter-prewarm
            spec:
              containers:
              - name: pause
                image: public.ecr.aws/eks-distro/kubernetes/pause:3.9
                resources:
                  requests:
                    cpu: 100m
                    memory: 128Mi
              terminationGracePeriodSeconds: 0
          PREWARM_EOF
            if ! kubectl wait pod karpenter-prewarm -n kube-system --for=condition=Ready --timeout=8m; then
              echo "=== PREWARM TIMEOUT — diagnostic dump ==="
              echo "--- EC2NodeClass fips ---"
              kubectl get ec2nodeclass fips -o yaml 2>/dev/null || true
              echo "--- NodePools ---"
              kubectl get nodepool -o yaml 2>/dev/null || true
              echo "--- NodeClaims ---"
              kubectl get nodeclaims -o yaml 2>/dev/null || true
              echo "--- Karpenter controller logs (last 200 lines) ---"
              kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=200 --since=15m 2>/dev/null || true
              echo "--- Prewarm pod events ---"
              kubectl describe pod karpenter-prewarm -n kube-system 2>/dev/null || true
              echo "--- All nodes ---"
              kubectl get nodes -o wide 2>/dev/null || true
              exit 1
            fi
            kubectl delete pod karpenter-prewarm -n kube-system --wait=false
            echo "✓ Karpenter node provisioned, proceeding with ArgoCD install"
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
            helm uninstall argocd -n argocd 2>/dev/null || true
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
                --overwrite 2>/dev/null || true
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
            until [ "$(kubectl get application hypershift -n argocd \
                -o jsonpath='{.status.health.status}' 2>/dev/null)" = "Healthy" ]; do
              if [ $SECONDS -ge $_HS_DEADLINE ]; then
                echo "ERROR: hypershift Application not Healthy after 30 minutes" >&2
                kubectl get application hypershift -n argocd -o yaml 2>/dev/null || true
                exit 1
              fi
              _HS_STATUS=$(kubectl get application hypershift -n argocd \
                -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NotFound")
              echo "  hypershift health: $${_HS_STATUS} ($(( _HS_DEADLINE - SECONDS ))s remaining)"
              kubectl logs -n hypershift-install -l job-name=hypershift-install \
                --tail=5 2>/dev/null || true
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
        },
        {
          name  = "RC_AWS_ACCOUNT_ID"
          value = var.rc_aws_account_id
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