# Log Collector ECS task — runs oc adm inspect for specified namespaces,
# tars the output, uploads to S3, and exits. The calling script polls for
# task completion, then downloads from S3.

# =============================================================================
# Task Definition
# =============================================================================
# Namespaces and S3 key are passed as environment variable overrides at run time.

resource "aws_ecs_task_definition" "log_collector" {
  family                   = "${var.cluster_id}-log-collector"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.log_collector_cpu
  memory                   = var.log_collector_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.log_collector.arn

  container_definitions = jsonencode([
    {
      name      = "log-collector"
      image     = var.container_image
      essential = true

      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail

          echo "=== Log Collector ==="
          echo "Cluster:    $CLUSTER_NAME"
          echo "Namespaces: $INSPECT_NAMESPACES"
          echo "S3 dest:    s3://$S3_BUCKET/$S3_KEY"
          echo ""

          # Configure kubectl
          aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

          # Resolve namespaces — "all" discovers every namespace on the cluster
          if [[ "$INSPECT_NAMESPACES" == "all" ]]; then
            INSPECT_NAMESPACES=$(kubectl get namespaces -o jsonpath='{range .items[*]}ns/{.metadata.name} {end}')
          fi
          echo "Resolved namespaces: $INSPECT_NAMESPACES"

          # Run oc adm inspect (5 min timeout to prevent hangs on large clusters)
          echo "Running oc adm inspect..."
          # shellcheck disable=SC2086
          timeout 300 oc adm inspect $INSPECT_NAMESPACES --dest-dir=/tmp/inspect-logs || true

          # Collect cluster-scoped and CRD resources in batches of 5
          resources=(
            nodes
            hostedclusters.hypershift.openshift.io
            hostedcontrolplanes.hypershift.openshift.io
            nodepools.hypershift.openshift.io
            awsendpointservices.hypershift.openshift.io
            controlplanecomponents.hypershift.openshift.io
            clustersizingconfigurations.scheduling.hypershift.openshift.io
            nodepools.karpenter.sh
            nodeclaims.karpenter.sh
            ec2nodeclasses.karpenter.k8s.aws
            openshiftec2nodeclasses.karpenter.openshift.io
            clusters.cluster.x-k8s.io
            machines.cluster.x-k8s.io
            machinesets.cluster.x-k8s.io
            machinedeployments.cluster.x-k8s.io
            awsmachines.infrastructure.cluster.x-k8s.io
            awsmachinetemplates.infrastructure.cluster.x-k8s.io
            awsclusters.infrastructure.cluster.x-k8s.io
            applications.argoproj.io
            applicationsets.argoproj.io
            certificates.cert-manager.io
            certificaterequests.cert-manager.io
            clusterissuers.cert-manager.io
            externalsecrets.external-secrets.io
            clustersecretstores.external-secrets.io
            prometheusrules.monitoring.coreos.com
            thanoscompacts.monitoring.thanos.io
            thanosqueries.monitoring.thanos.io
            thanosreceivers.monitoring.thanos.io
            thanosrulers.monitoring.thanos.io
            thanosstores.monitoring.thanos.io
            targetgroupbindings.elbv2.k8s.aws
            ec2nodeclasses.karpenter.k8s.aws
            secretproviderclasses.secrets-store.csi.x-k8s.io
          )
          batch=0
          for resource in "$${resources[@]}"; do
            timeout 180 oc adm inspect "$resource" --all-namespaces --dest-dir=/tmp/inspect-logs 2>/dev/null || true &
            batch=$((batch + 1))
            if [[ $batch -ge 5 ]]; then
              wait
              batch=0
            fi
          done
          wait

          # Tar and upload to S3
          echo "Uploading to S3..."
          tar czf /tmp/inspect-logs.tar.gz -C /tmp inspect-logs
          aws s3 cp /tmp/inspect-logs.tar.gz "s3://$S3_BUCKET/$S3_KEY"

          echo "Done."
        EOF
      ]

      environment = [
        {
          name  = "CLUSTER_NAME"
          value = var.cluster_name
        },
        {
          name  = "AWS_REGION"
          value = data.aws_region.current.name
        },
        {
          name  = "INSPECT_NAMESPACES"
          value = "ns/default"
        },
        {
          name  = "S3_KEY"
          value = "inspect-logs.tar.gz"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bastion.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "log-collector"
        }
      }
    }
  ])

  tags = var.tags
}

# =============================================================================
# Task Role — EKS access + S3 upload
# =============================================================================

resource "aws_iam_role" "log_collector" {
  name = "${var.cluster_id}-log-collector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "log_collector_eks" {
  name = "eks-access"
  role = aws_iam_role.log_collector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSListClusters"
        Effect = "Allow"
        Action = [
          "eks:ListClusters"
        ]
        Resource = "*"
      },
      {
        Sid    = "EKSClusterAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:AccessKubernetesApi"
        ]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${local.account_id}:cluster/${var.cluster_name}"
      }
    ]
  })
}

resource "aws_iam_role_policy" "log_collector_s3" {
  name = "s3-logs-upload"
  role = aws_iam_role.log_collector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Upload"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "arn:aws:s3:::bastion-log-collection-*/*"
      }
    ]
  })
}

# =============================================================================
# EKS Access — Grants the log-collector task role cluster admin access
# =============================================================================

resource "aws_eks_access_entry" "log_collector" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.log_collector.arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "log_collector" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.log_collector.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.log_collector]
}
