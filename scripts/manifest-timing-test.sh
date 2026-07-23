#!/usr/bin/env bash
# Usage: ./manifest-timing-test.sh <mc-name> [--namespace <ns>] [--name <name>] [--no-cleanup]
# Dependencies: kubectl, jq
set -euo pipefail

MC_NAME="${1:-}"
[[ -z "$MC_NAME" ]] && { echo "Usage: $0 <mc-name> [--namespace <ns>] [--name <name>] [--no-cleanup]" >&2; exit 1; }
shift

CM_NAMESPACE="default"
MANIFEST_NAME="hf-timing-test"
CLEANUP=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)  CM_NAMESPACE="$2"; shift 2 ;;
    --name)       MANIFEST_NAME="$2"; shift 2 ;;
    --no-cleanup) CLEANUP=false;      shift   ;;
    *) echo "Unknown flag: $1" >&2; exit 1    ;;
  esac
done

for cmd in kubectl jq; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found" >&2; exit 1; }
done

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] OK   $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN $*"; }
fail() { echo "[$(date '+%H:%M:%S')] FAIL $*" >&2; exit 1; }

# Manifest CR must live in a namespace named after the MC
MANIFEST_NS="$MC_NAME"

if ! kubectl get namespace "$MANIFEST_NS" &>/dev/null; then
  log "Namespace '${MANIFEST_NS}' not found on RC — creating..."
  kubectl create namespace "$MANIFEST_NS"
fi

# Build ConfigMap content and apply Manifest CR
# watch:true causes the operator to write a ReadDesire so kube-applier
# mirrors the live ConfigMap status back into status.resourceStatuses
log "Applying Manifest CR '${MANIFEST_NS}/${MANIFEST_NAME}'..."

CM_COMPACT=$(jq -nc \
  --arg name "$MANIFEST_NAME" \
  --arg ns   "$CM_NAMESPACE" \
  '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$name,namespace:$ns},data:{"created-by":"manifest-timing-test"}}')

kubectl apply -f - <<YAML
apiVersion: hyperfleet.io/v1alpha1
kind: Manifest
metadata:
  name: ${MANIFEST_NAME}
  namespace: ${MANIFEST_NS}
spec:
  managementCluster: ${MC_NAME}
  resources:
    - resource: configmaps
      watch: true
      content: ${CM_COMPACT}
YAML

ok "Manifest CR applied"

# Start timer
START_S=$(date +%s)
START_NS=$(date +%s%N 2>/dev/null || echo "")

elapsed_ms() {
  local now_ns
  now_ns=$(date +%s%N 2>/dev/null || echo "")
  if [[ -n "$START_NS" && -n "$now_ns" && "${#now_ns}" -gt 10 ]]; then
    echo $(( (now_ns - START_NS) / 1000000 ))
  else
    echo $(( ($(date +%s) - START_S) * 1000 ))
  fi
}

# Poll until ReadDesire status appears in status.resourceStatuses
POLL_INTERVAL=3
TIMEOUT=300
log "Polling Manifest status (timeout=${TIMEOUT}s, interval=${POLL_INTERVAL}s)..."

LAST_PHASE=""
SYNCED_LOGGED=false
READ_STATUS_MS=""

while true; do
  if (( $(date +%s) - START_S > TIMEOUT )); then
    warn "Timed out after ${TIMEOUT}s"
    break
  fi

  MJSON=$(kubectl get manifest.hyperfleet.io "${MANIFEST_NAME}" -n "${MANIFEST_NS}" -o json 2>/dev/null || true)
  [[ -z "$MJSON" ]] && { sleep "$POLL_INTERVAL"; continue; }

  PHASE=$(    echo "$MJSON" | jq -r '.status.phase // "Pending"')
  APPLIED=$(  echo "$MJSON" | jq -r '.status.appliedResources // 0')
  SYNCED=$(   echo "$MJSON" | jq -r '(.status.conditions // []) | map(select(.type=="Synced")) | .[0].status // "Unknown"')
  RS_COUNT=$( echo "$MJSON" | jq '(.status.resourceStatuses // []) | length')

  if [[ "$PHASE" != "$LAST_PHASE" ]]; then
    log "+$(elapsed_ms)ms  phase=${PHASE}  appliedResources=${APPLIED}"
    LAST_PHASE="$PHASE"
  fi

  if [[ "$SYNCED" == "True" && "$SYNCED_LOGGED" == "false" ]]; then
    ok "+$(elapsed_ms)ms  Synced=True (ApplyDesires confirmed by kube-applier)"
    SYNCED_LOGGED=true
  fi

  if (( RS_COUNT > 0 )); then
    READ_STATUS_MS=$(elapsed_ms)
    ok "+${READ_STATUS_MS}ms  ReadDesire status populated (resourceStatuses count=${RS_COUNT})"
    echo ""
    echo "$MJSON" | jq '.status.resourceStatuses[]'
    break
  fi

  sleep "$POLL_INTERVAL"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Timing Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ManagementCluster : ${MC_NAME}"
echo "  Manifest CR       : ${MANIFEST_NS}/${MANIFEST_NAME}"
echo "  ConfigMap target  : ${CM_NAMESPACE}/${MANIFEST_NAME} (on MC)"
if [[ -n "$READ_STATUS_MS" ]]; then
  echo "  Time to ReadDesire status : ${READ_STATUS_MS}ms"
else
  echo "  Time to ReadDesire status : TIMED OUT (>${TIMEOUT}s)"
fi
echo ""

if $CLEANUP; then
  log "Deleting Manifest CR..."
  kubectl delete manifest.hyperfleet.io "${MANIFEST_NAME}" -n "${MANIFEST_NS}" --ignore-not-found
  ok "Cleaned up"
else
  warn "Skipping cleanup (--no-cleanup). Manifest '${MANIFEST_NS}/${MANIFEST_NAME}' left in place."
fi
