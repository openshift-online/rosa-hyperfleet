#!/bin/bash
set -euo pipefail

# Unified port-forward script via SSM bastion hop
#
# Handles the full two-hop chain:
#   1. Starts/reuses a bastion ECS task
#   2. Runs kubectl port-forward inside the bastion (bastion -> K8s service)
#   3. Starts SSM port forwarding (laptop -> bastion)
#
# Usage:
#   ./bastion-port-forward.sh                          # Interactive mode
#   ./bastion-port-forward.sh maestro                  # Maestro HTTP (8080) + gRPC (8090)
#   ./bastion-port-forward.sh argocd                   # ArgoCD HTTPS (8443) via regional
#   ./bastion-port-forward.sh argocd management        # ArgoCD HTTPS (8443) via management
#   ./bastion-port-forward.sh custom                   # Custom service (interactive prompts)

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 [service] [cluster_type]

Services:
  maestro   - Maestro HTTP (8080) + gRPC (8090)  [regional only]
  argocd    - ArgoCD server HTTPS (8443)          [regional or management]
  custom    - Custom service (will prompt for details)

Cluster type:
  regional    - Regional cluster
  management  - Management cluster

Run with no arguments for interactive mode (requires fzf).
EOF
  exit 1
}

fzf_pick() {
  local header="$1"
  shift
  printf '%s\n' "$@" | fzf --height=~10 --layout=reverse --header="$header" --no-info
}

# ── Parse arguments or run interactively ─────────────────────────────────────

if [ $# -ge 2 ]; then
  SERVICE="$1"
  CLUSTER_TYPE="$2"
elif [ $# -eq 1 ]; then
  SERVICE="$1"
  if ! command -v fzf &>/dev/null; then
    echo "Error: CLUSTER_TYPE is required. Provide it as the second argument or install fzf for interactive selection."
    echo ""
    usage
  fi
  CLUSTER_TYPE=$(fzf_pick "Select cluster type:" "regional" "management")
else
  if ! command -v fzf &>/dev/null; then
    echo "Error: fzf is required for interactive mode. Install it or pass arguments directly."
    echo ""
    usage
  fi

  # Interactive: pick cluster type first, then show available services
  CLUSTER_TYPE=$(fzf_pick "Select cluster type:" "regional" "management")

  if [ "$CLUSTER_TYPE" = "regional" ]; then
    SERVICE=$(fzf_pick "Select service (${CLUSTER_TYPE}):" \
      "maestro   - Maestro HTTP + gRPC" \
      "argocd    - ArgoCD server HTTPS" \
      "custom    - Custom service / ports")
  else
    SERVICE=$(fzf_pick "Select service (${CLUSTER_TYPE}):" \
      "argocd    - ArgoCD server HTTPS" \
      "custom    - Custom service / ports")
  fi
  SERVICE="${SERVICE%%[[:space:]]*}"
fi

# ── Validate ─────────────────────────────────────────────────────────────────

case "$SERVICE" in
  maestro|argocd|custom) ;;
  *) echo "Error: unknown service '$SERVICE'"; echo ""; usage ;;
esac

case "$CLUSTER_TYPE" in
  regional|management) ;;
  *) echo "Error: invalid cluster type '$CLUSTER_TYPE'"; echo ""; usage ;;
esac

if [ "$SERVICE" = "maestro" ] && [ "$CLUSTER_TYPE" != "regional" ]; then
  echo "Error: maestro is only available on regional clusters."
  exit 1
fi

# ── Build port-forward definitions ───────────────────────────────────────────
# Each entry: "label remote_port local_port k8s_svc k8s_namespace k8s_svc_port"

case "$SERVICE" in
  maestro)
    FORWARDS=(
      "Maestro-HTTP 8080 8080 maestro-http maestro-server 8080"
      "Maestro-gRPC 8090 8090 maestro-grpc maestro-server 8090"
    )
    ;;
  argocd)
    FORWARDS=(
      "ArgoCD-Server 8443 8443 argocd-server argocd 443"
    )
    ;;
  custom)
    echo ""
    read -rp "Kubernetes namespace: " K8S_NS
    read -rp "Service name (without svc/ prefix): " K8S_SVC
    read -rp "Service port [443]: " K8S_SVC_PORT
    K8S_SVC_PORT="${K8S_SVC_PORT:-443}"
    read -rp "Local port [${K8S_SVC_PORT}]: " LOCAL_PORT
    LOCAL_PORT="${LOCAL_PORT:-$K8S_SVC_PORT}"
    REMOTE_PORT="$LOCAL_PORT"

    FORWARDS=(
      "Custom ${REMOTE_PORT} ${LOCAL_PORT} ${K8S_SVC} ${K8S_NS} ${K8S_SVC_PORT}"
    )
    ;;
esac

# ── Start / reuse bastion task ───────────────────────────────────────────────

CONFIG_DIR="terraform/config/${CLUSTER_TYPE}-cluster"
TASK_FILE="bastion_task_${CLUSTER_TYPE}.json"
CURRENT_DIR=$(pwd)

if [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: Terraform config directory '$CONFIG_DIR' not found."
  exit 1
fi

# ── Confirm AWS identity ─────────────────────────────────────────────────────

echo ""
echo "==> Checking AWS identity..."
CALLER_ID=$(aws sts get-caller-identity --output json)
AWS_ACCOUNT=$(echo "$CALLER_ID" | jq -r '.Account')
AWS_ARN=$(echo "$CALLER_ID" | jq -r '.Arn')

echo "    Account:      $AWS_ACCOUNT"
echo "    ARN:          $AWS_ARN"
echo "    Cluster type: $CLUSTER_TYPE"
echo "    Service:      $SERVICE"
echo ""
read -rp "Connect to bastion and start port-forwarding? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "==> Starting/verifying bastion task for $CLUSTER_TYPE cluster..."

cd "$CONFIG_DIR"

eval "$(terraform output -raw bastion_run_task_command)" >/dev/null

CLUSTER=$(terraform output -raw bastion_ecs_cluster_name)
TASK_ID=$(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')

if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "None" ] || [ "$TASK_ID" = "null" ]; then
  echo "Error: No ECS tasks found for cluster $CLUSTER, aborting."
  exit 1
fi

echo "==> Waiting for task to be running..."
aws ecs wait tasks-running --cluster "$CLUSTER" --tasks "$TASK_ID"

RUNTIME_ID=$(aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --tasks "$TASK_ID" \
  --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' \
  --output text)

if [[ -z "$RUNTIME_ID" || "$RUNTIME_ID" == "None" ]]; then
  echo "Error: runtime_id not found for task '$TASK_ID' in cluster '$CLUSTER'"
  exit 1
fi

echo "{\"cluster_type\":\"$CLUSTER_TYPE\",\"cluster\":\"$CLUSTER\",\"task_id\":\"$TASK_ID\",\"runtime_id\":\"$RUNTIME_ID\"}" > "$CURRENT_DIR/$TASK_FILE"

cd "$CURRENT_DIR"

echo ""
echo "==> Bastion task ready"
echo "    Cluster:    $CLUSTER"
echo "    Task ID:    $TASK_ID"
echo "    Runtime ID: $RUNTIME_ID"
echo ""

# ── Pre-flight: check local ports are free ───────────────────────────────────

for entry in "${FORWARDS[@]}"; do
  read -r label _ local_port _ _ _ <<< "$entry"
  if lsof -iTCP:"$local_port" -sTCP:LISTEN -t &>/dev/null; then
    echo "Error: Local port ${local_port} (${label}) is already in use."
    echo "Kill the process using it first: lsof -iTCP:${local_port} -sTCP:LISTEN"
    exit 1
  fi
done

# ── Port forwarding ─────────────────────────────────────────────────────────

SSM_PIDS=()

cleanup() {
  echo ""
  echo "Stopping all port-forward sessions..."
  for pid in "${SSM_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

TARGET="ecs:${CLUSTER}_${TASK_ID}_${RUNTIME_ID}"

# Kill stale port-forwards on bastion
echo "==> Cleaning up stale port-forwards on bastion..."
aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task "$TASK_ID" \
  --container bastion \
  --interactive \
  --command "pkill -f kubectl.port-forward || true" &>/dev/null || true
sleep 2

# Start kubectl port-forward(s) inside the bastion (one ECS exec per forward).
# The ECS exec session is short-lived but kubectl keeps running in the container.
for entry in "${FORWARDS[@]}"; do
  read -r label remote_port local_port k8s_svc k8s_ns k8s_svc_port <<< "$entry"

  echo "==> [bastion] kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns}"
  aws ecs execute-command \
    --cluster "$CLUSTER" \
    --task "$TASK_ID" \
    --container bastion \
    --interactive \
    --command "kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns} --address 0.0.0.0" &
done
# Not tracked in SSM_PIDS — the ECS exec processes are expected to exit

# Wait for kubectl to bind inside the bastion
echo ""
echo "==> Waiting for kubectl port-forward(s) to be ready..."
sleep 5

# Hop 2: SSM port forward from laptop to bastion
for entry in "${FORWARDS[@]}"; do
  read -r label remote_port local_port _ _ _ <<< "$entry"

  echo "==> [local] SSM forwarding ${label} (localhost:${local_port} -> bastion:${remote_port})..."
  aws ssm start-session \
    --target "$TARGET" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"${remote_port}\"],\"localPortNumber\":[\"${local_port}\"]}" &
  SSM_PIDS+=($!)
done

echo ""
echo "==> Port forwarding active. Forwarded ports:"
for entry in "${FORWARDS[@]}"; do
  read -r label _ local_port _ _ _ <<< "$entry"
  echo "    ${label}: localhost:${local_port}"
done

# For ArgoCD, fetch and display the admin password from the bastion.
# Use a marker prefix so we can extract the password from the SSM session noise.
if [ "$SERVICE" = "argocd" ]; then
  echo ""
  echo "==> Fetching ArgoCD admin password..."
  PASS_OUTPUT=$(aws ecs execute-command \
    --cluster "$CLUSTER" \
    --task "$TASK_ID" \
    --container bastion \
    --interactive \
    --command "sh -c \"echo ARGOCD_PW=\$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d)\"" 2>/dev/null || true)
  ARGOCD_PASS=$(echo "$PASS_OUTPUT" | grep -o 'ARGOCD_PW=.*' | cut -d= -f2 | tr -d '[:space:]')
  echo ""
  echo "    ArgoCD UI:       https://localhost:8443"
  echo "    Username:        admin"
  if [ -n "$ARGOCD_PASS" ]; then
    echo "    Password:        ${ARGOCD_PASS}"
  else
    echo "    Password:        (could not retrieve - run on bastion manually):"
    echo "                     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d"
  fi
fi

echo ""
echo "Press Ctrl+C to stop."

# Wait for any SSM session to exit — if one dies, tear everything down
while true; do
  for pid in "${SSM_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      echo ""
      echo "Error: SSM port-forward session (PID $pid) exited unexpectedly."
      exit 1
    fi
  done
  sleep 2
done
