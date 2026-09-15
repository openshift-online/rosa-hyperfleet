#!/usr/bin/env bash
# Ephemeral CI: tunnel regional Alertmanager to localhost for e2e-cli silence specs.
#
# Pattern (same as scripts/dev/ephemeral-env.sh port-forward):
#   1. Bastion: kubectl port-forward monitoring-alertmanager:9093 on 0.0.0.0
#   2. Test pod: SSM port-forward bastion:9093 -> localhost:9093
#
# Requires: AWS creds with ECS exec + SSM (rrp-rc), session-manager-plugin, kubectl on bastion.
# Sets ALERTMANAGER_URL (Makefile maps to E2E_ALERTMANAGER_URL for ginkgo).

set -euo pipefail

_AM_BASTION_PF_PID=""
_AM_SSM_PID=""
_AM_ECS_CLUSTER=""
_AM_TASK_ID=""
_AM_CLEANUP_REGISTERED=false

cleanup_alertmanager_forward() {
  if [[ -n "${_AM_SSM_PID}" ]]; then
    kill "${_AM_SSM_PID}" 2>/dev/null || true
    wait "${_AM_SSM_PID}" 2>/dev/null || true
    _AM_SSM_PID=""
  fi
  if [[ -n "${_AM_BASTION_PF_PID}" ]]; then
    kill "${_AM_BASTION_PF_PID}" 2>/dev/null || true
    wait "${_AM_BASTION_PF_PID}" 2>/dev/null || true
    _AM_BASTION_PF_PID=""
  fi
  if [[ -n "${_AM_ECS_CLUSTER}" && -n "${_AM_TASK_ID}" ]]; then
    aws ecs execute-command --cluster "${_AM_ECS_CLUSTER}" --task "${_AM_TASK_ID}" --container bastion \
      --interactive --command "pkill -f 'port-forward.*monitoring-alertmanager' || true" &>/dev/null || true
  fi
}

# Start bastion + SSM tunnel. Uses CLUSTER_PREFIX (eph-<hash>-) when cluster_id omitted.
start_alertmanager_forward() {
  local cluster_id="${1:-}"
  local local_port="${ALERTMANAGER_LOCAL_PORT:-9093}"
  local remote_port="${ALERTMANAGER_REMOTE_PORT:-9093}"
  local am_url="http://127.0.0.1:${local_port}"

  if [[ -z "${cluster_id}" ]]; then
    [[ -n "${CLUSTER_PREFIX:-}" ]] || {
      echo "ERROR: CLUSTER_PREFIX required to derive ephemeral cluster id" >&2
      return 1
    }
    cluster_id="${CLUSTER_PREFIX}regional"
  fi

  if ! command -v session-manager-plugin >/dev/null 2>&1; then
    echo "ERROR: session-manager-plugin not installed (required for SSM port forward)" >&2
    return 1
  fi

  local repo_root script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  # shellcheck source=scripts/dev/env-common.sh
  source "${repo_root}/scripts/dev/env-common.sh"

  echo "=== Alertmanager forward: cluster_id=${cluster_id} ==="
  unset task_id
  bastion_run_task "${cluster_id}"
  _AM_ECS_CLUSTER="${ecs_cluster}"
  _AM_TASK_ID="${task_id}"
  sleep 12

  aws ecs execute-command --cluster "${ecs_cluster}" --task "${task_id}" --container bastion \
    --interactive --command "pkill -f 'port-forward.*monitoring-alertmanager' || true" &>/dev/null || true
  sleep 2

  echo "=== Bastion kubectl port-forward to Alertmanager ==="
  aws ecs execute-command --cluster "${ecs_cluster}" --task "${task_id}" --container bastion \
    --interactive \
    --command "kubectl port-forward svc/monitoring-alertmanager ${remote_port}:9093 -n monitoring --address 0.0.0.0" &
  _AM_BASTION_PF_PID=$!
  sleep 10

  local runtime_id target
  runtime_id=$(aws ecs describe-tasks --cluster "${ecs_cluster}" --tasks "${task_id}" \
    --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' --output text)
  target="ecs:${ecs_cluster}_${task_id}_${runtime_id}"

  echo "=== SSM port-forward localhost:${local_port} -> bastion:${remote_port} ==="
  aws ssm start-session \
    --target "${target}" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"${remote_port}\"],\"localPortNumber\":[\"${local_port}\"]}" &
  _AM_SSM_PID=$!
  sleep 15

  if curl -sf "${am_url}/-/healthy" >/dev/null; then
    export ALERTMANAGER_URL="${am_url}"
    export E2E_ALERTMANAGER_URL="${am_url}"
    if [[ "${_AM_CLEANUP_REGISTERED}" == "false" ]]; then
      trap cleanup_alertmanager_forward EXIT
      _AM_CLEANUP_REGISTERED=true
    fi
    echo "ALERTMANAGER_FORWARD_OK url=${ALERTMANAGER_URL}"
    return 0
  fi

  echo "ERROR: Alertmanager health check failed at ${am_url}" >&2
  cleanup_alertmanager_forward
  return 1
}
