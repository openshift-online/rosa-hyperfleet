#!/usr/bin/env bash
# FIPS compliance verification for EKS clusters with Bottlerocket FIPS nodes.
# Covers: Kubernetes objects, node host state, distroless container FIPS, container user space, application binaries.
#
# Usage:
#   ./verify-fips.sh [-n <namespace>] [-x <namespaces>] [-N <namespace>] [-i <image>]
#
# Flags:
#   -n <namespace>     Check only this namespace (default: all non-system namespaces)
#   -x <namespaces>    Comma-separated namespaces to exclude (default: kube-node-lease)
#   -N <namespace>     Namespace for the diagnostic DaemonSet (default: kube-system)
#   -i <image>         Image for the diagnostic DaemonSet (default: alpine:3)
set -euo pipefail

CHECK_NAMESPACES=""
EXCLUDE_NAMESPACES="kube-node-lease"
NODE_CHECK_NS="kube-system"
NODE_CHECK_IMAGE="alpine:3"

while getopts ":n:x:N:i:" opt; do
  case $opt in
    n) CHECK_NAMESPACES="$OPTARG" ;;
    x) EXCLUDE_NAMESPACES="$OPTARG" ;;
    N) NODE_CHECK_NS="$OPTARG" ;;
    i) NODE_CHECK_IMAGE="$OPTARG" ;;
    :) echo "Error: -$OPTARG requires an argument" >&2; exit 1 ;;
    \?) echo "Error: unknown option -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
if [[ $# -ne 0 ]]; then
  echo "Error: unexpected positional arguments: $*" >&2
  exit 1
fi

PASS=0; FAIL=0; SKIP=0
FAILURES=()
PASSES=()
WORKLOAD_FAILS=()  # entries: "pod_short|binary_basename|binary_type"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

# ─── Output helpers ───────────────────────────────────────────────────────────
pass()   { printf "  ${GREEN}[PASS]${RESET} %s\n" "$1"; ((++PASS)); PASSES+=("$1"); }
fail()   { printf "  ${RED}[FAIL]${RESET} %s\n" "$1"; ((++FAIL)); FAILURES+=("$1"); }
skip()   { printf "  ${YELLOW}[SKIP]${RESET} %s\n" "$1"; ((++SKIP)); }
header() { printf "\n${BOLD}=== %s ===${RESET}\n" "$1"; }

get_namespaces() {
  if [[ -n "$CHECK_NAMESPACES" ]]; then
    echo "$CHECK_NAMESPACES" | tr ',' '\n'
  else
    local exclude_re
    exclude_re=$(echo "$EXCLUDE_NAMESPACES" | tr ',' '|')
    kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -vE "^(${exclude_re})$"
  fi
}

cleanup() {
  kubectl delete daemonset/fips-node-check -n "$NODE_CHECK_NS" \
    --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

print_workload_summary() {
  [[ ${#WORKLOAD_FAILS[@]} -eq 0 ]] && return

  declare -A _grp  # "bin|type" -> space-separated pod_short list
  for _e in "${WORKLOAD_FAILS[@]}"; do
    local _ps _bn _bt
    IFS='|' read -r _ps _bn _bt <<< "$_e"
    _grp["${_bn}|${_bt}"]+="${_ps} "
  done

  local -a _c1=() _c2=() _c3=()
  for _key in "${!_grp[@]}"; do
    local _bn _bt _total _first _comp
    IFS='|' read -r _bn _bt <<< "$_key"
    _total=$(echo "${_grp[$_key]}" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)
    _first=$(echo "${_grp[$_key]}" | tr ' ' '\n' | grep -v '^$' | sort -u | head -1)
    if [[ "$_total" -gt 1 ]]; then
      _comp="${_first} ×${_total}"
    else
      _comp="$_first"
    fi
    _c1+=("$_comp")
    _c2+=("${_bn} (${_bt})")
    _c3+=("Real finding")
  done

  local _h1="Component" _h2="Binary" _h3="Assessment"
  local _w1=${#_h1} _w2=${#_h2} _w3=${#_h3}
  for _i in "${!_c1[@]}"; do
    [[ ${#_c1[$_i]} -gt $_w1 ]] && _w1=${#_c1[$_i]}
    [[ ${#_c2[$_i]} -gt $_w2 ]] && _w2=${#_c2[$_i]}
    [[ ${#_c3[$_i]} -gt $_w3 ]] && _w3=${#_c3[$_i]}
  done

  local _r1 _r2 _r3
  _r1=$(printf '─%.0s' $(seq 1 $((_w1 + 2))))
  _r2=$(printf '─%.0s' $(seq 1 $((_w2 + 2))))
  _r3=$(printf '─%.0s' $(seq 1 $((_w3 + 2))))

  printf "\n${BOLD}Workload Compliance Summary (failures requiring remediation):${RESET}\n"
  printf "  ┌%s┬%s┬%s┐\n" "$_r1" "$_r2" "$_r3"
  printf "  │ %-${_w1}s │ %-${_w2}s │ %-${_w3}s │\n" "$_h1" "$_h2" "$_h3"
  printf "  ├%s┼%s┼%s┤\n" "$_r1" "$_r2" "$_r3"
  for _i in "${!_c1[@]}"; do
    [[ $_i -gt 0 ]] && printf "  ├%s┼%s┼%s┤\n" "$_r1" "$_r2" "$_r3"
    printf "  │ %-${_w1}s │ %-${_w2}s │ %-${_w3}s │\n" \
      "${_c1[$_i]}" "${_c2[$_i]}" "${_c3[$_i]}"
  done
  printf "  └%s┴%s┴%s┘\n" "$_r1" "$_r2" "$_r3"
  printf "\n  These binaries need to be rebuilt with FIPS-compliant Go (Red Hat golang-fips\n"
  printf "  or BoringCrypto), Python (system OpenSSL), or C++ (BoringSSL with FIPS module).\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Kubernetes Object Checks (NodeClass / NodePool)
# ─────────────────────────────────────────────────────────────────────────────
check_kubernetes_objects() {
  header "Kubernetes: NodeClass / NodePool"

  if ! kubectl get crd nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; then
    skip "NodeClass CRD not found — skipping (Karpenter not installed)"
    return
  fi

  echo ""
  echo "  NodePool -> NodeClass bindings:"
  kubectl get nodepool -o json 2>/dev/null | jq -r \
    '.items[] | "    \(.metadata.name) -> \(.spec.template.spec.nodeClassRef.name)"'

  local non_fips_pools
  non_fips_pools=$(kubectl get nodepool -o json 2>/dev/null | jq -r \
    '.items[] | select(.spec.template.spec.nodeClassRef.name != "fips") | .metadata.name')
  if [[ -z "$non_fips_pools" ]]; then
    pass "All NodePools reference the FIPS NodeClass"
  else
    fail "NodePools NOT using FIPS NodeClass: $non_fips_pools"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Node Host State
#    Deploys a privileged DaemonSet that mounts the host root to inspect:
#      - /proc/sys/crypto/fips_enabled  (must be 1)
#      - /sys/kernel/security/lockdown  (must be [integrity] or [confidentiality])
#      - apiclient report fips          (Bottlerocket only, via /run/api.sock)
# ─────────────────────────────────────────────────────────────────────────────
check_node_host_state() {
  header "Node Host State"

  kubectl apply -n "$NODE_CHECK_NS" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fips-node-check
  namespace: ${NODE_CHECK_NS}
  labels:
    app: fips-node-check
spec:
  selector:
    matchLabels:
      app: fips-node-check
  template:
    metadata:
      labels:
        app: fips-node-check
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: check
        image: ${NODE_CHECK_IMAGE}
        command: ["sleep", "3600"]
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
      volumes:
      - name: host-root
        hostPath:
          path: /
EOF

  echo "  Waiting for node-check pods..."
  kubectl rollout status daemonset/fips-node-check -n "$NODE_CHECK_NS" --timeout=120s >/dev/null
  sleep 2

  local pods
  pods=$(kubectl get pods -n "$NODE_CHECK_NS" -l app=fips-node-check \
    --no-headers -o custom-columns=POD:.metadata.name)

  for pod in $pods; do
    local node
    node=$(kubectl get pod "$pod" -n "$NODE_CHECK_NS" \
      -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    if [[ -z "$node" ]]; then
      skip "pod $pod no longer exists — node evicted or pod was not admitted; re-run to recheck"
      continue
    fi
    echo ""
    printf "  --- Node: %s ---\n" "$node"

    # /proc/sys/crypto/fips_enabled must be 1
    local fips_val
    fips_val=$(kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
      cat /host/proc/sys/crypto/fips_enabled 2>/dev/null | tr -d '[:space:]' || echo "ERR")
    if [[ "$fips_val" == "1" ]]; then
      pass "$node: /proc/sys/crypto/fips_enabled=1"
    else
      fail "$node: /proc/sys/crypto/fips_enabled=${fips_val} (expected 1)"
    fi

    # Kernel lockdown must be [integrity] or [confidentiality] if it was configured.
    # Signal: check whether lockdown= appears in the kernel command line.
    #   - lockdown= present in cmdline but state is [none] → real failure (misconfigured)
    #   - lockdown= absent from cmdline → never configured; SKIP with a note
    local lockdown
    lockdown=$(kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
      cat /host/sys/kernel/security/lockdown 2>/dev/null | tr -d '\n' || echo "ERR")
    local cmdline_lockdown=""
    cmdline_lockdown=$(kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
      grep -oE 'lockdown=[^ ]+' /host/proc/cmdline 2>/dev/null || echo "")
    if echo "$lockdown" | grep -qE '\[integrity\]|\[confidentiality\]'; then
      pass "$node: kernel lockdown=$lockdown"
    elif [[ -n "$cmdline_lockdown" ]]; then
      fail "$node: kernel lockdown=${lockdown} (cmdline sets ${cmdline_lockdown} but lockdown is not active)"
    else
      skip "$node: kernel lockdown=${lockdown} — lockdown= not in cmdline; add lockdown=integrity to kernel args to enable (DISA STIG RHEL-09-212035 / Bottlerocket NodeClass kernelLockdown)"
    fi

    # Bottlerocket: apiclient report fips (requires /run/api.sock)
    if kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
        test -S /host/run/api.sock 2>/dev/null; then
      local report
      report=$(kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
        chroot /host /usr/bin/apiclient report fips 2>&1 || echo "")
      local fips_lines
      fips_lines=$(echo "$report" | grep -E '^\[PASS\]|^\[FAIL\]' || true)
      if [[ -z "$fips_lines" ]]; then
        fail "$node: apiclient report fips produced no output or failed (output: ${report:-<empty>})"
      else
        while IFS= read -r line; do
          if echo "$line" | grep -q '^\[PASS\]'; then
            pass "$node: apiclient: $line"
          else
            fail "$node: apiclient: $line"
          fi
        done <<< "$fips_lines"
      fi
    else
      skip "$node: /run/api.sock not found — Bottlerocket apiclient check skipped"
    fi

    # ── RHCOS / RHEL host checks ──────────────────────────────────────────
    if kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
        grep -qE '^ID="?(rhcos|rhel)"?' /host/etc/os-release 2>/dev/null; then

      # /etc/system-fips is created by fips-mode-setup when FIPS is initialized
      if kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
          test -f /host/etc/system-fips 2>/dev/null; then
        pass "$node: /etc/system-fips present"
      else
        fail "$node: /etc/system-fips missing — fips-mode-setup may not have completed"
      fi

      # System crypto policy must be FIPS (or a FIPS subpolicy like FIPS:OSPP)
      if kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
          test -x /host/usr/bin/update-crypto-policies 2>/dev/null; then
        local crypto_pol
        crypto_pol=$(kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
          chroot /host update-crypto-policies --show 2>/dev/null \
          | tr -d '[:space:]' || echo "ERR")
        if echo "$crypto_pol" | grep -qE "^FIPS"; then
          pass "$node: system crypto policy=${crypto_pol}"
        else
          fail "$node: system crypto policy=${crypto_pol} (expected FIPS or FIPS:*)"
        fi
      else
        skip "$node: update-crypto-policies not found"
      fi

      # fips-mode-setup --check is the authoritative RHEL FIPS verification
      if kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
          test -x /host/usr/sbin/fips-mode-setup 2>/dev/null; then
        if kubectl exec "$pod" -n "$NODE_CHECK_NS" -- \
            chroot /host fips-mode-setup --check >/dev/null 2>&1; then
          pass "$node: fips-mode-setup --check"
        else
          fail "$node: fips-mode-setup --check — FIPS not fully initialized on host"
        fi
      else
        skip "$node: fips-mode-setup not available"
      fi
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Minimal-Image Container FIPS Verification
#    "Distroless" / minimal images strip out shell, package manager, and debug
#    tools (nm, strings) to reduce attack surface. Because we cannot inspect
#    binaries from inside the container, the node DaemonSet from
#    check_node_host_state is reused to reach the container's process via the
#    host /proc filesystem. Three host-level checks are run:
#      - Image label   (com.redhat.fips=true on Red Hat FIPS images)
#      - /proc/<pid>/maps  (libcrypto loaded by the running process)
#      - /proc/<pid>/exe   (FIPS crypto symbols compiled into the binary)
# ─────────────────────────────────────────────────────────────────────────────
check_distroless_fips() {
  header "Minimal/Distroless Container FIPS Verification"
  printf "  %s\n" "(Distroless = stripped-down image with no shell or debug tools; checks run via host /proc)"

  local ds_pods
  ds_pods=$(kubectl get pods -n "$NODE_CHECK_NS" -l app=fips-node-check \
    --no-headers -o custom-columns=POD:.metadata.name 2>/dev/null || true)
  if [[ -z "$ds_pods" ]]; then
    skip "node-check DaemonSet not running — distroless checks skipped"
    return
  fi

  # Bottlerocket containerd socket — crictl requires explicit endpoint inside chroot.
  local crictl="crictl --runtime-endpoint unix:///run/containerd/containerd.sock"

  local -A _node_dsp
  for _dsp in $ds_pods; do
    local _n
    _n=$(kubectl get pod "$_dsp" -n "$NODE_CHECK_NS" \
      -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    [[ -n "$_n" ]] && _node_dsp["$_n"]="$_dsp"
  done

  local found_any=false

  for ns in $(get_namespaces); do
    local pods
    pods=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running \
      -l 'app!=fips-node-check' \
      --no-headers -o custom-columns=POD:.metadata.name 2>/dev/null || true)
    [[ -z "$pods" ]] && continue

    for pod in $pods; do
      local containers
      containers=$(kubectl get pod "$pod" -n "$ns" \
        -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n' || true)

      for container in $containers; do
        # Skip containers that have nm or strings — handled by check_workload_fips.
        if kubectl exec "$pod" -n "$ns" -c "$container" -- \
            which nm >/dev/null 2>&1 || \
           kubectl exec "$pod" -n "$ns" -c "$container" -- \
            which strings >/dev/null 2>&1; then
          continue
        fi

        found_any=true
        local target="$ns/$pod/$container"
        local pod_short
        pod_short=$(echo "$pod" | sed -E 's/-[a-z0-9]{5,10}-[a-z0-9]{4,5}$//' 2>/dev/null || echo "$pod")

        echo ""
        printf "  --- %s (minimal/distroless image — no shell or debug tools inside container) ---\n" "$target"

        local node
        node=$(kubectl get pod "$pod" -n "$ns" \
          -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
        local ds_pod="${_node_dsp[$node]:-}"
        if [[ -z "$ds_pod" ]]; then
          skip "$target: no node-check pod on node $node"
          continue
        fi

        local image
        image=$(kubectl get pod "$pod" -n "$ns" \
          -o jsonpath="{.spec.containers[?(@.name==\"${container}\")].image}" \
          2>/dev/null || echo "")
        local img_base
        img_base=$(basename "${image%%:*}" 2>/dev/null || echo "$image")

        local container_id
        container_id=$(kubectl get pod "$pod" -n "$ns" \
          -o jsonpath="{.status.containerStatuses[?(@.name==\"${container}\")].containerID}" \
          2>/dev/null | sed 's|.*://||' || echo "")

        # ── 1. Image label: com.redhat.fips ──────────────────────────────────
        local label_out
        label_out=$(kubectl exec "$ds_pod" -n "$NODE_CHECK_NS" -- \
          chroot /host $crictl inspecti "$image" 2>/dev/null | \
          grep -i 'com.redhat.fips' | head -1 | tr -d ' "' || echo "")
        if echo "$label_out" | grep -qi ':true'; then
          pass "$target: image label com.redhat.fips=true"
        elif [[ -n "$label_out" ]]; then
          fail "$target: image label com.redhat.fips not true (${label_out})"
          WORKLOAD_FAILS+=("${pod_short}|${img_base}|distroless")
        else
          skip "$target: com.redhat.fips label absent — not a Red Hat FIPS image, or label unavailable via crictl"
        fi

        # ── Resolve host PID via cgroup search ───────────────────────────────
        # Each container's processes carry the container ID in their cgroup path.
        # Searching /proc/[0-9]*/cgroup avoids crictl entirely and works on any
        # container runtime (containerd, cri-o) regardless of socket/config.
        if [[ -z "$container_id" ]]; then
          skip "$target: cannot resolve container ID — skipping /proc checks"
          continue
        fi

        local host_pid
        host_pid=$(kubectl exec "$ds_pod" -n "$NODE_CHECK_NS" -- \
          sh -c "grep -rl '${container_id}' /host/proc/[0-9]*/cgroup 2>/dev/null \
            | head -1 | sed 's|/host/proc/||;s|/cgroup||'" \
          2>/dev/null | tr -d '[:space:]' || echo "")
        if [[ -z "$host_pid" || "$host_pid" == "0" ]]; then
          skip "$target: cannot locate host PID for $container_id in /proc cgroups — skipping /proc checks"
          continue
        fi

        # ── 2. /proc/<pid>/maps: runtime crypto library ───────────────────────
        local maps_line
        maps_line=$(kubectl exec "$ds_pod" -n "$NODE_CHECK_NS" -- \
          grep -iE 'libcrypto|libssl' /host/proc/"$host_pid"/maps 2>/dev/null | head -1 || echo "")
        if [[ -n "$maps_line" ]]; then
          local lib
          lib=$(echo "$maps_line" | grep -oE 'libcrypto[^ ]*|libssl[^ ]*' | head -1)
          pass "$target: /proc/$host_pid/maps: ${lib:-libcrypto} loaded at runtime"
        else
          fail "$target: /proc/$host_pid/maps: no libcrypto/libssl — OpenSSL not loaded by running process"
          WORKLOAD_FAILS+=("${pod_short}|${img_base}|distroless")
        fi

        # ── 3. /proc/<pid>/exe: FIPS compile-time symbols ────────────────────
        local has_fips_sym
        has_fips_sym=$(kubectl exec "$ds_pod" -n "$NODE_CHECK_NS" -- \
          sh -c "grep -qaE '_goboringcrypto|_Cfunc_go_openssl|fips_module|FIPS_mode|boringssl_fips_self_test' \
            /host/proc/${host_pid}/exe 2>/dev/null && echo yes || echo no" \
          2>/dev/null | tail -1 | tr -d '[:space:]' || echo "no")
        if [[ "$has_fips_sym" == "yes" ]]; then
          pass "$target: /proc/$host_pid/exe: FIPS crypto symbols present"
        else
          skip "$target: /proc/$host_pid/exe: no FIPS compile-time symbols — FIPS may be via runtime linkage; verify via build provenance"
        fi
      done
    done
  done

  if [[ "$found_any" == "false" ]]; then
    skip "no distroless containers found in checked namespaces"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Workload FIPS Compliance
#    For every running container, discovers the application binary then branches
#    on ldd output to apply the right checks:
#
#      C binary (links libcrypto) → OpenSSL version + FIPS provider + crypto
#                                   policy + MD5 forced-failure test
#      Go / static binary         → BoringCrypto / Red Hat golang-fips symbol
#                                   check via nm (preferred) or strings fallback
# ─────────────────────────────────────────────────────────────────────────────
check_workload_fips() {
  header "Workload FIPS Compliance"

  local init_wrappers="tini|dumb-init|s6-svscan|pause|sh|bash"

  for ns in $(get_namespaces); do
    local pods
    pods=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running \
      -l 'app!=fips-node-check' \
      --no-headers -o custom-columns=POD:.metadata.name 2>/dev/null || true)
    [[ -z "$pods" ]] && continue

    for pod in $pods; do
      local containers
      containers=$(kubectl get pod "$pod" -n "$ns" \
        -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n' || true)

      for container in $containers; do
        local target="$ns/$pod/$container"
        local pod_short
        pod_short=$(echo "$pod" | sed -E 's/-[a-z0-9]{5,10}-[a-z0-9]{4,5}$//' 2>/dev/null || echo "$pod")

        # ── Resolve application binary ────────────────────────────────────────
        # /proc/1/exe is unreliable in two cases:
        #   1. Known init wrappers (tini, dumb-init, etc.)
        #   2. hostPID containers (node-exporter): PID 1 is host systemd, unreadable
        # In both cases fall back to command[0] from the pod spec, then args[0].
        local binary
        binary=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
          readlink -f /proc/1/exe 2>/dev/null || echo "")

        local needs_fallback=false
        if [[ -z "$binary" ]]; then
          needs_fallback=true
        elif echo "$binary" | grep -qE "(${init_wrappers})$"; then
          needs_fallback=true
        fi

        if [[ "$needs_fallback" == "true" ]]; then
          local spec_cmd
          spec_cmd=$(kubectl get pod "$pod" -n "$ns" \
            -o jsonpath="{.spec.containers[?(@.name==\"${container}\")].command[0]}" 2>/dev/null || echo "")
          if [[ -z "$spec_cmd" ]]; then
            spec_cmd=$(kubectl get pod "$pod" -n "$ns" \
              -o jsonpath="{.spec.containers[?(@.name==\"${container}\")].args[0]}" 2>/dev/null || echo "")
          fi
          if [[ -n "$spec_cmd" ]]; then
            local resolved
            resolved=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
              sh -c "command -v \"$spec_cmd\" 2>/dev/null || readlink -f \"$spec_cmd\" 2>/dev/null" 2>/dev/null || echo "")
            [[ -n "$resolved" ]] && binary="$resolved"
          fi
        fi

        if [[ -z "$binary" ]]; then
          skip "$target: cannot resolve application binary"
          continue
        fi

        echo ""
        printf "  --- %s (%s) ---\n" "$target" "$binary"

        # ── Detect binary type via ldd or /proc/1/maps ───────────────────────
        # /proc/1/maps is a ldd-free fallback that works in UBI/minimal images
        # and correctly shows runtime-loaded libraries (e.g. golang-fips).
        local libcrypto_link=""
        if kubectl exec "$pod" -n "$ns" -c "$container" -- \
            which ldd >/dev/null 2>&1; then
          libcrypto_link=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
            ldd "$binary" 2>/dev/null | grep "libcrypto" || echo "")
        fi
        if [[ -z "$libcrypto_link" ]]; then
          libcrypto_link=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
            grep libcrypto /proc/1/maps 2>/dev/null || echo "")
        fi

        if [[ -n "$libcrypto_link" ]]; then
          # ── C binary: OpenSSL checks ──────────────────────────────────────

          if echo "$libcrypto_link" | grep -qE "(/usr/lib|/lib64)/libcrypto"; then
            pass "$target: libcrypto -> system path"
          else
            fail "$target: libcrypto not from system path (possibly bundled): $libcrypto_link"
            WORKLOAD_FAILS+=("${pod_short}|$(basename "$binary")|C/OpenSSL")
          fi

          if ! kubectl exec "$pod" -n "$ns" -c "$container" -- \
              which openssl >/dev/null 2>&1; then
            skip "$target: openssl CLI not in container — skipping provider/MD5 checks"
            continue
          fi

          local openssl_ver
          openssl_ver=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
            openssl version 2>/dev/null || echo "ERR")
          if echo "$openssl_ver" | grep -qE "^OpenSSL 3\."; then
            pass "$target: $openssl_ver"
          else
            fail "$target: $openssl_ver (OpenSSL 3.x required for FIPS 140-3)"
            WORKLOAD_FAILS+=("${pod_short}|$(basename "$binary")|C/OpenSSL")
          fi

          local providers
          providers=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
            openssl list -providers -verbose 2>/dev/null || echo "")
          if echo "$providers" | grep -qi "fips"; then
            pass "$target: OpenSSL FIPS provider loaded"
          else
            fail "$target: OpenSSL FIPS provider not loaded"
            WORKLOAD_FAILS+=("${pod_short}|$(basename "$binary")|C/OpenSSL")
          fi

          if kubectl exec "$pod" -n "$ns" -c "$container" -- \
              which update-crypto-policies >/dev/null 2>&1; then
            local policy
            policy=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
              update-crypto-policies --show 2>/dev/null | tr -d '[:space:]' || echo "ERR")
            if [[ "$policy" == "FIPS" ]]; then
              pass "$target: system crypto policy=FIPS"
            else
              fail "$target: system crypto policy=${policy} (expected FIPS)"
            fi
          else
            skip "$target: update-crypto-policies not found (non-RHEL/UBI image)"
          fi

          if kubectl exec "$pod" -n "$ns" -c "$container" -- \
              openssl md5 /dev/null >/dev/null 2>&1; then
            fail "$target: MD5 not blocked — FIPS not enforced in OpenSSL"
            WORKLOAD_FAILS+=("${pod_short}|$(basename "$binary")|C/OpenSSL")
          else
            pass "$target: MD5 blocked by FIPS"
          fi

        else
          # ── Go / Python / C++ binary detection ───────────────────────────
          # Resolve scan tool once; used for all symbol searches below.
          local scan_tool=""
          if kubectl exec "$pod" -n "$ns" -c "$container" -- \
              which nm >/dev/null 2>&1; then
            scan_tool="nm"
          elif kubectl exec "$pod" -n "$ns" -c "$container" -- \
              which strings >/dev/null 2>&1; then
            scan_tool="strings"
          fi

          # ── Python binary ─────────────────────────────────────────────────
          if echo "$binary" | grep -qE '/python[0-9.]*$'; then
            local py_ssl_ver
            py_ssl_ver=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
              python3 -c "import ssl; print(ssl.OPENSSL_VERSION)" 2>/dev/null || echo "ERR")
            if echo "$py_ssl_ver" | grep -qE "^OpenSSL 3\."; then
              pass "$target: Python ssl: $py_ssl_ver"
            else
              fail "$target: Python ssl: $py_ssl_ver (OpenSSL 3.x required)"
              WORKLOAD_FAILS+=("${pod_short}|$(basename "$binary")|Python")
            fi

            local py_md5
            py_md5=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
              python3 -c "import hashlib; hashlib.md5(b'test')" 2>&1 || true)
            if echo "$py_md5" | grep -qiE "valueerror|disabled for fips|unsupported hash"; then
              pass "$target: Python MD5 blocked by FIPS"
            else
              fail "$target: Python MD5 not blocked — FIPS not enforced"
              WORKLOAD_FAILS+=("${pod_short}|$(basename "$binary")|Python")
            fi
            continue
          fi

          # If no scan tool, we cannot inspect the binary at all (distroless image).
          if [[ -z "$scan_tool" ]]; then
            skip "$target: nm and strings unavailable (minimal/distroless image — no debug tools in container). Verify FIPS compliance via build provenance: check SBOM, build logs, or image labels for the Red Hat FIPS toolchain."
            continue
          fi

          # ── Detect Go binary via runtime markers ──────────────────────────
          local is_go=false
          if [[ -n "$scan_tool" ]]; then
            local go_marker_count
            go_marker_count=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
              sh -c "$scan_tool \"$binary\" 2>/dev/null | grep -c 'go.buildinfo\|runtime.main\|_rt0_amd64' || echo 0" \
              2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")
            [[ "$go_marker_count" -gt 0 ]] && is_go=true
          fi

          if [[ "$is_go" == "true" ]]; then
            # ── Go binary: BoringCrypto / golang-fips symbol check ─────────
            if [[ -z "$scan_tool" ]]; then
              fail "$target: nm and strings both unavailable — cannot verify Go FIPS symbols"
              continue
            fi
            local fips_sym_count
            fips_sym_count=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
              sh -c "$scan_tool \"$binary\" 2>/dev/null | grep -c '_goboringcrypto\|_Cfunc_go_openssl\|fips_module' || echo 0" \
              2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")
            if [[ "$fips_sym_count" -gt 0 ]]; then
              pass "$target: FIPS Go crypto symbols found ($fips_sym_count)"
            else
              fail "$target: no FIPS Go crypto symbols — binary may not be FIPS-compliant"
              WORKLOAD_FAILS+=("${pod_short}|$(basename "$binary")|Go")
            fi

          else
            # ── Unknown runtime: probe for BoringSSL symbols as positive evidence ──
            # Only classify as C++ if BoringSSL FIPS symbols are present; absence
            # of those symbols does not confirm C++ — skip rather than false-fail.
            if [[ -z "$scan_tool" ]]; then
              fail "$target: nm and strings both unavailable — cannot verify FIPS symbols"
              continue
            fi
            local cpp_fips_count
            cpp_fips_count=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
              sh -c "$scan_tool \"$binary\" 2>/dev/null | grep -c 'FIPS_mode\|boringssl_fips_self_test\|CRYPTO_is_FIPS_approved_algorithm\|EVP_AEAD_CTX_init' || echo 0" \
              2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")
            if [[ "$cpp_fips_count" -gt 0 ]]; then
              pass "$target: C++ BoringSSL FIPS symbols found ($cpp_fips_count)"
            else
              skip "$target: no BoringSSL FIPS symbols — runtime unknown, verify via build provenance"
            fi
          fi
        fi
      done
    done
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
check_kubernetes_objects
check_node_host_state
check_distroless_fips
check_workload_fips

print_workload_summary

echo ""
printf "${BOLD}════════════════════════════════════════════${RESET}\n"
printf "${GREEN}  PASS: %d${RESET}  ${RED}FAIL: %d${RESET}  ${YELLOW}SKIP: %d${RESET}\n" "$PASS" "$FAIL" "$SKIP"
printf "${BOLD}════════════════════════════════════════════${RESET}\n"

if [[ ${#PASSES[@]} -gt 0 ]]; then
  echo ""
  printf "${BOLD}${GREEN}Passing Checks:${RESET}\n"
  printf "${GREEN}────────────────────────────────────────────${RESET}\n"
  for p in "${PASSES[@]}"; do
    printf "  ${GREEN}✓${RESET} %s\n" "$p"
  done
  printf "${GREEN}────────────────────────────────────────────${RESET}\n"
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  printf "${BOLD}${RED}Failed Checks:${RESET}\n"
  printf "${RED}────────────────────────────────────────────${RESET}\n"
  for f in "${FAILURES[@]}"; do
    printf "  ${RED}✗${RESET} %s\n" "$f"
  done
  printf "${RED}────────────────────────────────────────────${RESET}\n"
  exit 1
else
  echo ""
  printf "  ${GREEN}✓ All checks passed${RESET}\n"
  exit 0
fi
