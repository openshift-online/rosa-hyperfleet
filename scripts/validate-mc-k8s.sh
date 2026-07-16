#!/usr/bin/env bash
# Validate Kubernetes-level processes on a Management Cluster (MC).
#
# Usage:
#   ./scripts/validate-mc-k8s.sh                         # auto-derives CLUSTER_ID from kubectl context
#   CLUSTER_ID=<id> ./scripts/validate-mc-k8s.sh         # override if needed
#
# Prerequisites: active kubectl context pointing at the target MC, kubectl/jq on PATH.

set -euo pipefail

# Auto-derive CLUSTER_ID from the active kubectl context when not set explicitly.
# aws eks update-kubeconfig names contexts: arn:aws:eks:<region>:<account>:cluster/<name>
_ctx=$(kubectl config current-context 2>/dev/null || true)
if [[ -z "${CLUSTER_ID:-}" && "$_ctx" =~ :cluster/(.+)$ ]]; then
    CLUSTER_ID="${BASH_REMATCH[1]}"
fi
CLUSTER_ID="${CLUSTER_ID:?Cannot derive CLUSTER_ID — set it manually or ensure the active kubectl context points at an EKS cluster}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; ((++PASS)); }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; ((++FAIL)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; ((++WARN)); }

section() { echo; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pods_running() {
    local ns="$1" selector="${2:-}"
    local args=(-n "$ns" --no-headers)
    [[ -n "$selector" ]] && args+=(-l "$selector")

    if ! kubectl get pods "${args[@]}" 2>/dev/null | grep -q .; then
        return 2
    fi

    local not_running
    not_running=$(kubectl get pods "${args[@]}" 2>/dev/null \
        | awk '$3 ~ /^(Running|Completed)$/ { if ($3 == "Running") { split($2, r, "/"); if (r[1]+0 < r[2]+0) print }; next } { print }' \
        || true)
    [[ -z "$not_running" ]]
}

pod_count() {
    local ns="$1" selector="${2:-}"
    local args=(-n "$ns" --no-headers)
    [[ -n "$selector" ]] && args+=(-l "$selector")
    kubectl get pods "${args[@]}" 2>/dev/null | grep -c . || echo 0
}

# ---------------------------------------------------------------------------
# 1. Nodes
# ---------------------------------------------------------------------------

section "Nodes"

if ! _nodes_raw=$(kubectl get nodes --no-headers 2>/dev/null); then
    fail "Cannot list nodes — check kubeconfig and RBAC"
else
    not_ready=$(echo "$_nodes_raw" | awk '{print $2}' | grep -v "^Ready$" || true)
    if [[ -z "$not_ready" ]]; then
        node_count=$(echo "$_nodes_raw" | wc -l | tr -d ' ')
        pass "All ${node_count} nodes are Ready"
    else
        bad=$(echo "$not_ready" | wc -l | tr -d ' ')
        fail "${bad} node(s) not Ready"
    fi
fi

# Karpenter-provisioned nodes carry karpenter.sh/nodepool label
kp_nodes=$(kubectl get nodes -l "karpenter.sh/nodepool" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$kp_nodes" -ge 1 ]]; then
    pass "Karpenter-provisioned nodes present (${kp_nodes})"
else
    warn "No Karpenter-provisioned nodes found (may be expected if no workload scheduled yet)"
fi

# ---------------------------------------------------------------------------
# 2. HyperShift operator
# ---------------------------------------------------------------------------

section "HyperShift operator"

if kubectl get namespace hypershift &>/dev/null; then
    rc=0
    pods_running hypershift "app=operator" || rc=$?
    if [[ $rc -eq 0 ]]; then
        count=$(pod_count hypershift "app=operator")
        pass "HyperShift operator Running (${count} pod(s))"
    elif [[ $rc -eq 2 ]]; then
        fail "HyperShift operator: namespace exists but no operator pods found"
        echo "  [diag] hypershift-install Job:"
        kubectl get job hypershift-install -n hypershift-install --no-headers 2>/dev/null \
            | sed 's/^/    /' || echo "    job not found in namespace hypershift-install"
        echo "  [diag] Installer pod logs (last 40 lines):"
        kubectl logs -n hypershift-install -l "job-name=hypershift-install" \
            --tail=40 2>/dev/null | sed 's/^/    /' \
            || echo "    no logs — pod may have been evicted or namespace missing"
        echo "  [diag] Resources in hypershift namespace:"
        kubectl get all -n hypershift 2>/dev/null | sed 's/^/    /' || true
        echo "  [diag] Events in hypershift namespace:"
        kubectl get events -n hypershift --sort-by='.lastTimestamp' 2>/dev/null \
            | tail -10 | sed 's/^/    /' || true
    else
        fail "HyperShift operator pods not all Running"
        kubectl get pods -n hypershift -l "app=operator" --no-headers 2>/dev/null \
            | sed 's/^/    /' || true
        echo "  [diag] Events:"
        kubectl get events -n hypershift --sort-by='.lastTimestamp' 2>/dev/null \
            | tail -10 | sed 's/^/    /' || true
    fi
else
    fail "Namespace 'hypershift' does not exist — HyperShift not installed"
    echo "  [diag] Installer job:"
    kubectl get job hypershift-install -n hypershift-install 2>/dev/null \
        | sed 's/^/    /' || echo "    namespace hypershift-install not found"
fi

# ---------------------------------------------------------------------------
# 3. HostedClusters and NodePools
# ---------------------------------------------------------------------------

section "HostedClusters"

if ! kubectl api-resources --api-group=hypershift.openshift.io 2>/dev/null | grep -q HostedCluster; then
    warn "HyperShift CRDs not registered — skipping HostedCluster checks"
else
    hc_total=$(kubectl get hostedclusters -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$hc_total" -eq 0 ]]; then
        warn "No HostedClusters found"
    else
        pass "HostedClusters found: ${hc_total}"

        # Check each HC is Available
        while IFS= read -r line; do
            hc_ns=$(echo "$line" | awk '{print $1}')
            hc_name=$(echo "$line" | awk '{print $2}')
            available=$(kubectl get hostedcluster "$hc_name" -n "$hc_ns" \
                -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
            if [[ "$available" == "True" ]]; then
                pass "HostedCluster ${hc_ns}/${hc_name} Available=True"
            else
                reason=$(kubectl get hostedcluster "$hc_name" -n "$hc_ns" \
                    -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null || true)
                fail "HostedCluster ${hc_ns}/${hc_name} Available=${available:-Unknown} — ${reason:-no detail}"
            fi
        done < <(kubectl get hostedclusters -A --no-headers 2>/dev/null)
    fi

    np_total=$(kubectl get nodepools -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$np_total" -eq 0 ]]; then
        warn "No NodePools found"
    else
        while IFS= read -r line; do
            np_ns=$(echo "$line" | awk '{print $1}')
            np_name=$(echo "$line" | awk '{print $2}')
            desired=$(kubectl get nodepool "$np_name" -n "$np_ns" \
                -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
            ready=$(kubectl get nodepool "$np_name" -n "$np_ns" \
                -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
            ready="${ready:-0}"
            if [[ "$ready" -ge 1 ]]; then
                pass "NodePool ${np_ns}/${np_name}: ${ready}/${desired} replicas Ready"
            else
                fail "NodePool ${np_ns}/${np_name}: ${ready}/${desired} replicas Ready"
            fi
        done < <(kubectl get nodepools -A --no-headers 2>/dev/null)
    fi
fi

# ---------------------------------------------------------------------------
# 4. Control plane pods per HostedCluster
# ---------------------------------------------------------------------------

section "HostedCluster control plane pods"

if kubectl api-resources --api-group=hypershift.openshift.io 2>/dev/null | grep -q HostedCluster; then
    while IFS= read -r line; do
        hc_ns=$(echo "$line" | awk '{print $1}')
        hc_name=$(echo "$line" | awk '{print $2}')
        cp_ns="clusters-${hc_name}"
        rc=0
        pods_running "$cp_ns" || rc=$?
        if [[ $rc -eq 0 ]]; then
            count=$(pod_count "$cp_ns")
            pass "Control plane pods for ${hc_name} (${cp_ns}): ${count} Running"
        elif [[ $rc -eq 2 ]]; then
            warn "No control plane pods in ${cp_ns} yet"
        else
            not_running=$(kubectl get pods -n "$cp_ns" --no-headers 2>/dev/null \
                | awk '{print $1, $3}' | grep -v "Running\|Completed" || true)
            fail "Control plane pods not all Running in ${cp_ns}:"
            echo "$not_running" | sed 's/^/       /'
        fi
    done < <(kubectl get hostedclusters -A --no-headers 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# 5. Core add-ons
# ---------------------------------------------------------------------------

section "Core add-ons (kube-system)"

declare -A CORE_SELECTORS=(
    ["CoreDNS"]="k8s-app=kube-dns"
    ["vpc-cni (aws-node)"]="k8s-app=aws-node"
    ["kube-proxy"]="k8s-app=kube-proxy"
)

for label in "${!CORE_SELECTORS[@]}"; do
    selector="${CORE_SELECTORS[$label]}"
    rc=0
    pods_running kube-system "$selector" || rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "${label} Running"
    elif [[ $rc -eq 2 ]]; then
        warn "${label}: no pods found"
    else
        fail "${label}: pods not all Running"
    fi
done

# ---------------------------------------------------------------------------
# 6. Maestro agent
# ---------------------------------------------------------------------------

section "Maestro agent"

rc=0
pods_running maestro-agent || rc=$?
if [[ $rc -eq 0 ]]; then
    count=$(pod_count maestro-agent)
    pass "Maestro agent: ${count} pod(s) Running"
elif [[ $rc -eq 2 ]]; then
    warn "Maestro agent: no pods in namespace 'maestro-agent'"
else
    fail "Maestro agent: pods not all Running"
fi

# ---------------------------------------------------------------------------
# 7. ArgoCD (optional on MC)
# ---------------------------------------------------------------------------

section "ArgoCD (if present)"

if kubectl get namespace argocd &>/dev/null; then
    if ! _apps_raw=$(kubectl get applications -n argocd --no-headers 2>/dev/null); then
        fail "ArgoCD: cannot list applications — check RBAC and ArgoCD CRD availability"
    else
        not_synced=$(echo "$_apps_raw" \
            | awk '{print $1, $2, $3}' | grep -v "Synced.*Healthy" | grep -v "Synced.*Progressing" || true)
        if [[ -z "$not_synced" ]]; then
            total=$(echo "$_apps_raw" | wc -l | tr -d ' ')
            pass "All ${total} ArgoCD applications Synced"
        else
            count=$(echo "$not_synced" | wc -l | tr -d ' ')
            fail "${count} ArgoCD application(s) not Synced/Healthy"
            echo "$not_synced" | sed 's/^/       /'
            while IFS= read -r _line; do
                _app=$(echo "$_line" | awk '{print $1}')
                _sync=$(echo "$_line" | awk '{print $2}')
                _health=$(echo "$_line" | awk '{print $3}')
                echo "  [diag] ${_app} (${_sync}/${_health}):"
                if [[ "$_sync" == "OutOfSync" ]]; then
                    kubectl get application "$_app" -n argocd \
                        -o jsonpath='{.status.resources}' 2>/dev/null \
                        | jq -r '.[] | select(.status != "Synced") | "    \(.kind)/\(.name): \(.status) \(.health.status // "")"' \
                        2>/dev/null | head -10 || true
                fi
                if [[ "$_health" == "Degraded" ]]; then
                    _app_health_msg=$(kubectl get application "$_app" -n argocd \
                        -o jsonpath='{.status.health.message}' 2>/dev/null || true)
                    [[ -n "$_app_health_msg" ]] && echo "    health: ${_app_health_msg}"
                    kubectl get application "$_app" -n argocd \
                        -o jsonpath='{.status.conditions}' 2>/dev/null \
                        | jq -r '.[]? | "    condition: \(.type): \(.message // "-")"' 2>/dev/null || true
                    kubectl get application "$_app" -n argocd \
                        -o jsonpath='{.status.resources}' 2>/dev/null \
                        | jq -r '.[]? | select(.health.status == "Degraded" or .health.status == "Missing" or .health.status == "Unknown") | "    \(.kind)/\(.name): \(.health.status) — \(.health.message // "-")"' \
                        2>/dev/null | head -10 || true
                fi
            done <<< "$not_synced"
        fi
    fi
else
    warn "ArgoCD not installed on this MC (namespace 'argocd' absent)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

section "Summary"
echo -e "  ${GREEN}PASS${RESET}: ${PASS}  ${RED}FAIL${RESET}: ${FAIL}  ${YELLOW}WARN${RESET}: ${WARN}"

[[ "$FAIL" -eq 0 ]]
