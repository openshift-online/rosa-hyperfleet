#!/usr/bin/env bash
# Validate Kubernetes-level processes on the Regional Cluster (RC).
#
# Usage:
#   ./scripts/validate-rc-k8s.sh                         # auto-derives CLUSTER_ID from kubectl context
#   CLUSTER_ID=<id> ./scripts/validate-rc-k8s.sh         # override if needed
#
# Prerequisites: active kubectl context pointing at the RC, kubectl/jq on PATH.

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

# Returns 0 if all pods in a namespace with an optional label selector are Running.
# $1=namespace  $2=optional label selector (e.g. app=foo)
pods_running() {
    local ns="$1" selector="${2:-}"
    local args=(-n "$ns" --no-headers)
    [[ -n "$selector" ]] && args+=(-l "$selector")

    if ! kubectl get pods "${args[@]}" 2>/dev/null | grep -q .; then
        return 2  # no pods found
    fi

    local not_running
    not_running=$(kubectl get pods "${args[@]}" 2>/dev/null \
        | awk '$3 ~ /^(Running|Completed)$/ { if ($3 == "Running") { split($2, r, "/"); if (r[1]+0 < r[2]+0) print }; next } { print }' \
        || true)
    [[ -z "$not_running" ]]
}

# Returns pod count in a namespace with optional label selector.
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
        fail "Nodes not Ready: $(echo "$not_ready" | wc -l | tr -d ' ') node(s)"
    fi
fi

bootstrap_nodes=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=${CLUSTER_ID}-karpenter-bootstrap" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$bootstrap_nodes" -ge 2 ]]; then
    pass "Karpenter bootstrap node group: ${bootstrap_nodes} node(s) present"
else
    fail "Karpenter bootstrap node group: expected ≥2 nodes, found ${bootstrap_nodes}"
fi

taint_count=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=${CLUSTER_ID}-karpenter-bootstrap" \
    -o json 2>/dev/null \
    | jq '[.items[] | select((.spec.taints // []) | any(.key == "CriticalAddonsOnly"))] | length')
if [[ "$taint_count" -eq "$bootstrap_nodes" && "$bootstrap_nodes" -ge 1 ]]; then
    pass "Bootstrap nodes have CriticalAddonsOnly taint (${taint_count}/${bootstrap_nodes})"
else
    fail "CriticalAddonsOnly taint missing on some bootstrap nodes (${taint_count}/${bootstrap_nodes} tainted)"
fi

# ---------------------------------------------------------------------------
# 2. Karpenter
# ---------------------------------------------------------------------------

section "Karpenter"

if pods_running kube-system "app.kubernetes.io/name=karpenter"; then
    kp_count=$(pod_count kube-system "app.kubernetes.io/name=karpenter")
    pass "Karpenter pods Running (${kp_count})"
else
    fail "Karpenter pods not all Running in kube-system"
fi

# Verify Karpenter controller runs on bootstrap nodes (not on nodes it would provision)
kp_nodes=$(kubectl get pods -n kube-system -l "app.kubernetes.io/name=karpenter" \
    -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null || true)
if [[ -z "$kp_nodes" ]]; then
    warn "Karpenter pods have no nodeName assigned yet — still scheduling?"
else
    off_bootstrap=0
    for node in $kp_nodes; do
        ng=$(kubectl get node "$node" \
            -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/nodegroup}' 2>/dev/null || true)
        if [[ "$ng" != "${CLUSTER_ID}-karpenter-bootstrap" ]]; then
            ((off_bootstrap++))
        fi
    done
    if [[ "$off_bootstrap" -eq 0 ]]; then
        pass "Karpenter pods scheduled on bootstrap node group"
    else
        fail "${off_bootstrap} Karpenter pod(s) NOT on bootstrap node group"
    fi
fi

ec2nc_ready=$(kubectl get ec2nodeclass fips \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [[ "$ec2nc_ready" == "True" ]]; then
    pass "EC2NodeClass 'fips' Ready=True"
else
    # Distinguish transient vs hard failure
    val_reason=$(kubectl get ec2nodeclass fips \
        -o jsonpath='{.status.conditions[?(@.type=="ValidationSucceeded")].message}' 2>/dev/null || true)
    fail "EC2NodeClass 'fips' Ready=${ec2nc_ready:-Unknown} — ${val_reason:-no detail}"
fi

# The RC NodePool is named 'regional-workloads'; check all NodePools so this
# doesn't break if the name changes.
_np_names=$(kubectl get nodepools.karpenter.sh --no-headers 2>/dev/null | awk '{print $1}' || true)
if [[ -z "$_np_names" ]]; then
    fail "No NodePools found"
else
    while IFS= read -r _np; do
        np_ready=$(kubectl get nodepools.karpenter.sh "$_np" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [[ "$np_ready" == "True" ]]; then
            pass "NodePool '${_np}' Ready=True"
        else
            fail "NodePool '${_np}' Ready=${np_ready:-Unknown}"
            echo "  [diag] NodePool conditions:"
            kubectl get nodepools.karpenter.sh "$_np" -o jsonpath='{.status.conditions}' 2>/dev/null \
                | jq -r '.[] | "    \(.type)=\(.status): \(.message // "-")"' 2>/dev/null || true
            echo "  [diag] nodeClassRef: $(kubectl get nodepools.karpenter.sh "$_np" \
                -o jsonpath='{.spec.template.spec.nodeClassRef.name}' 2>/dev/null || echo 'unknown')"
            echo "  [diag] Recent Karpenter logs (errors):"
            kubectl logs -n kube-system -l "app.kubernetes.io/name=karpenter" --tail=50 2>/dev/null \
                | grep -iE "nodepool|error|failed" | tail -10 | sed 's/^/    /' || true
        fi
    done <<< "$_np_names"
fi

nc_count=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$nc_count" -ge 1 ]]; then
    pass "NodeClaims present (${nc_count}) — Karpenter has provisioned nodes"
else
    warn "No NodeClaims found — Karpenter has not yet provisioned any nodes"
fi

# ---------------------------------------------------------------------------
# 3. AWS Load Balancer Controller
# ---------------------------------------------------------------------------

section "AWS Load Balancer Controller"

if pods_running aws-load-balancer-controller "app.kubernetes.io/name=aws-load-balancer-controller"; then
    lbc_count=$(pod_count aws-load-balancer-controller "app.kubernetes.io/name=aws-load-balancer-controller")
    pass "LBC pods Running (${lbc_count})"
else
    fail "LBC pods not all Running in aws-load-balancer-controller"
fi

if kubectl get crd targetgroupbindings.elbv2.k8s.aws &>/dev/null; then
    pass "TargetGroupBinding CRD (elbv2.k8s.aws) registered"
else
    fail "TargetGroupBinding CRD missing — LBC may not have started cleanly"
fi

# ---------------------------------------------------------------------------
# 4. Core add-on daemonsets / deployments (kube-system)
# ---------------------------------------------------------------------------

section "Core add-ons (kube-system)"

declare -A CORE_SELECTORS=(
    ["CoreDNS"]="k8s-app=kube-dns"
    ["metrics-server"]="app.kubernetes.io/name=metrics-server"
    ["vpc-cni (aws-node)"]="k8s-app=aws-node"
    ["kube-proxy"]="k8s-app=kube-proxy"
    ["ebs-csi-node"]="app=ebs-csi-node"
    ["ebs-csi-controller"]="app=ebs-csi-controller"
    ["secrets-store-csi"]="app=secrets-store-csi-driver"
)

for label in "${!CORE_SELECTORS[@]}"; do
    selector="${CORE_SELECTORS[$label]}"
    rc=0
    pods_running kube-system "$selector" || rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "${label} Running"
    elif [[ $rc -eq 2 ]]; then
        warn "${label}: no pods found (may not be installed)"
    else
        fail "${label}: pods not all Running"
    fi
done

# Secrets Store CSI also deploys as provider in kube-system
if pods_running kube-system "app=csi-secrets-store-provider-aws"; then
    pass "AWS Secrets Store CSI provider Running"
else
    warn "AWS Secrets Store CSI provider: not found"
fi

# pod-identity-agent is installed as an EKS addon (Terraform-managed). The addon
# DaemonSet may not carry the standard app label, so check by DaemonSet name first.
_pia_rc=0
pods_running kube-system "app.kubernetes.io/name=eks-pod-identity-agent" || _pia_rc=$?
if [[ $_pia_rc -eq 0 ]]; then
    pass "pod-identity-agent Running"
elif kubectl get daemonset eks-pod-identity-agent -n kube-system &>/dev/null; then
    _pia_desired=$(kubectl get daemonset eks-pod-identity-agent -n kube-system \
        -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    _pia_ready=$(kubectl get daemonset eks-pod-identity-agent -n kube-system \
        -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    if [[ "$_pia_ready" -ge 1 ]]; then
        pass "pod-identity-agent Running (${_pia_ready}/${_pia_desired} ready, EKS addon)"
    else
        fail "pod-identity-agent DaemonSet exists but ${_pia_ready}/${_pia_desired} pods ready"
        kubectl get pods -n kube-system -l "app.kubernetes.io/name=eks-pod-identity-agent" \
            --no-headers 2>/dev/null | sed 's/^/    /' || true
        kubectl get events -n kube-system \
            --field-selector "involvedObject.name=eks-pod-identity-agent" \
            --sort-by='.lastTimestamp' 2>/dev/null | tail -5 | sed 's/^/    /' || true
    fi
else
    warn "pod-identity-agent: DaemonSet not found — EKS addon may not be installed"
fi

# ---------------------------------------------------------------------------
# 5. Platform services
# ---------------------------------------------------------------------------

section "Platform services"

declare -A PLATFORM_NS=(
    ["platform-api"]="platform-api"
    ["maestro-server"]="maestro-server"
)

for svc in "${!PLATFORM_NS[@]}"; do
    ns="${PLATFORM_NS[$svc]}"
    rc=0
    pods_running "$ns" || rc=$?
    if [[ $rc -eq 0 ]]; then
        count=$(pod_count "$ns")
        pass "${svc}: ${count} pod(s) Running"
    elif [[ $rc -eq 2 ]]; then
        warn "${svc}: namespace '${ns}' has no pods yet"
    else
        fail "${svc}: pods not all Running in ${ns}"
    fi
done

# ---------------------------------------------------------------------------
# 6. ArgoCD
# ---------------------------------------------------------------------------

section "ArgoCD"

if pods_running argocd "app.kubernetes.io/name=argocd-server"; then
    pass "ArgoCD server Running"
else
    fail "ArgoCD server not Running"
fi

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
        fail "${count} ArgoCD application(s) not Synced/Healthy:"
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
            if [[ "$_sync" == "Unknown" ]]; then
                kubectl get application "$_app" -n argocd \
                    -o jsonpath='{.status.conditions}' 2>/dev/null \
                    | jq -r '.[]? | "    condition: \(.type): \(.message // "-")"' 2>/dev/null || true
                _op_msg=$(kubectl get application "$_app" -n argocd \
                    -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)
                [[ -n "$_op_msg" ]] && echo "    operationState: ${_op_msg}"
            fi
        done <<< "$not_synced"
    fi

    progressing=$(echo "$_apps_raw" \
        | awk '{print $1, $2, $3}' | grep "Progressing" || true)
    if [[ -n "$progressing" ]]; then
        warn "Applications still progressing:"
        echo "$progressing" | sed 's/^/       /'
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

section "Summary"
echo -e "  ${GREEN}PASS${RESET}: ${PASS}  ${RED}FAIL${RESET}: ${FAIL}  ${YELLOW}WARN${RESET}: ${WARN}"

[[ "$FAIL" -eq 0 ]]
