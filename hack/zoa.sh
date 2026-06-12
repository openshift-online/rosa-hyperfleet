#!/usr/bin/env bash
# Compatible with both bash and zsh (meant to be sourced, not executed)
# ZOA CLI — Zero Operator Access shell wrapper
#
# Dependencies: curl, jq
#
# Setup:
#   1. Source this file:
#        source /path/to/rosa-regional-platform/hack/zoa.sh
#
#   2. Export AWS credentials (SigV4 auth):
#        eval "$(aws configure export-credentials --format env --profile rrp-regional-dev)"
#
#   3. Export the API Gateway URL:
#        export ZOA_API="https://<api-id>.execute-api.<region>.amazonaws.com/prod"
#
#      The region is extracted automatically from the ZOA_API URL
#      (e.g. us-east-1 from https://xyz.execute-api.us-east-1.amazonaws.com/prod)
#
# All commands require -t <cluster> to specify the target.

# Resolve binary paths at source time (avoids zsh command lookup issues in functions)
_ZOA_CURL="${commands[curl]:-$(whence -p curl 2>/dev/null || echo curl)}"
_ZOA_JQ="${commands[jq]:-$(whence -p jq 2>/dev/null || echo jq)}"

if [[ ! -x "$_ZOA_CURL" ]]; then
  echo "zoa: error: curl not found in PATH" >&2
fi
if [[ ! -x "$_ZOA_JQ" ]]; then
  echo "zoa: error: jq not found in PATH" >&2
fi

_zoa_request() {
  local method="$1" path="$2" body="${3:-}"
  local url="${ZOA_API}/api/v0${path}"
  local region temp
  temp="${ZOA_API#*.execute-api.}"
  region="${temp%%.*}"

  local args=(
    -s
    --aws-sigv4 "aws:amz:${region}:execute-api"
    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}"
    -H "x-amz-security-token: ${AWS_SESSION_TOKEN}"
    -H "Content-Type: application/json"
    -X "$method"
  )
  [[ -n "$body" ]] && args+=(-d "$body")
  args+=("$url")

  "$_ZOA_CURL" "${args[@]}"
}

_zoa_poll() {
  local id="$1" interval="${2:-3}" timeout="${3:-120}"
  local elapsed=0 exec_status result

  while (( elapsed < timeout )); do
    result=$(_zoa_request GET "/trusted-actions/runs/${id}")
    exec_status=$(printf '%s' "$result" | "$_ZOA_JQ" -r '.status // empty')

    case "$exec_status" in
      succeeded|failed|error|timed_out)
        printf '%s' "$result"
        return 0
        ;;
      "")
        printf "\r\033[K⚠ invalid response (%ds)" "$elapsed" >&2
        sleep "$interval"
        elapsed=$((elapsed + interval))
        ;;
      *)
        printf "\r\033[K⠋ %s (%ds)" "$exec_status" "$elapsed" >&2
        sleep "$interval"
        elapsed=$((elapsed + interval))
        ;;
    esac
  done

  printf "\r\033[K" >&2
  echo "error: timed out after ${timeout}s (status: ${exec_status})" >&2
  printf '%s' "$result"
  return 1
}

zoa() {
  if [[ -z "${ZOA_API:-}" ]]; then
    echo "error: ZOA_API not set. Export your API Gateway URL:" >&2
    echo "  export ZOA_API=\"https://<id>.execute-api.<region>.amazonaws.com/prod\"" >&2
    return 1
  fi

  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    run)      _zoa_run "$@" ;;
    get)      _zoa_get "$@" ;;
    logs)     _zoa_logs "$@" ;;
    runs)     _zoa_runs "$@" ;;
    audit)    _zoa_audit "$@" ;;
    actions)  _zoa_actions "$@" ;;
    describe) _zoa_describe "$@" ;;
    help|--help|-h) _zoa_help ;;
    *)
      echo "error: unknown command '$cmd'" >&2
      _zoa_help >&2
      return 1
      ;;
  esac
}

_zoa_run() {
  local action="" target="" namespace="" all_ns="false" selector=""
  local verbose="false" resource="" name="" jira=""
  local no_wait=false force=false dry_run=false
  local -a extra_params=()

  action="${1:-}"
  [[ -z "$action" ]] && { echo "error: usage: zoa run <action> -t <cluster> --jira <ticket> [flags]" >&2; return 1; }
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--target)     target="$2"; shift 2 ;;
      -n)              namespace="$2"; shift 2 ;;
      -A)              all_ns="true"; shift ;;
      -l)              selector="$2"; shift 2 ;;
      -v|--verbose)    verbose="true"; shift ;;
      --resource)      resource="$2"; shift 2 ;;
      --name)          name="$2"; shift 2 ;;
      --jira)          jira="$2"; shift 2 ;;
      --force)         force=true; shift ;;
      --dry-run)       dry_run=true; shift ;;
      --no-wait)       no_wait=true; shift ;;
      --param)         extra_params+=("$2"); shift 2 ;;
      *) echo "error: unknown flag '$1'" >&2; return 1 ;;
    esac
  done

  if [[ -z "$target" ]]; then
    echo "error: -t <cluster> is required" >&2
    return 1
  fi

  if [[ -z "$jira" ]]; then
    echo "error: --jira <ticket> is required (e.g. ROSAENG-1234)" >&2
    return 1
  fi

  local params="{}"
  [[ -n "$namespace" ]]  && params=$(printf '%s' "$params" | "$_ZOA_JQ" --arg v "$namespace" '. + {namespace: $v}')
  [[ "$all_ns" == "true" ]] && params=$(printf '%s' "$params" | "$_ZOA_JQ" '. + {all_namespaces: "true"}')
  [[ -n "$selector" ]]   && params=$(printf '%s' "$params" | "$_ZOA_JQ" --arg v "$selector" '. + {label_selector: $v}')
  [[ "$verbose" == "true" ]] && params=$(printf '%s' "$params" | "$_ZOA_JQ" '. + {verbose: "true"}')
  [[ -n "$resource" ]]   && params=$(printf '%s' "$params" | "$_ZOA_JQ" --arg v "$resource" '. + {resource: $v}')
  [[ -n "$name" ]]       && params=$(printf '%s' "$params" | "$_ZOA_JQ" --arg v "$name" '. + {name: $v}')

  for p in "${extra_params[@]+"${extra_params[@]}"}"; do
    local key="${p%%=*}" val="${p#*=}"
    params=$(printf '%s' "$params" | "$_ZOA_JQ" --arg k "$key" --arg v "$val" '. + {($k): $v}')
  done

  local body
  body=$("$_ZOA_JQ" -n --arg target "$target" --arg jira "$jira" --argjson params "$params" \
    --argjson force "$force" --argjson dry_run "$dry_run" \
    '{target_cluster: $target, jira: $jira, params: $params, force: $force, dry_run: $dry_run}')

  local submit
  submit=$(_zoa_request POST "/trusted-actions/${action}/run" "$body")

  local id executed_action
  id=$(printf '%s' "$submit" | "$_ZOA_JQ" -r '.id // empty')
  if [[ -z "$id" ]]; then
    printf '%s' "$submit" | "$_ZOA_JQ" .
    return 1
  fi

  executed_action=$(printf '%s' "$submit" | "$_ZOA_JQ" -r '.executed_action // empty')
  local suffix=""
  if [[ -n "$executed_action" ]]; then
    suffix=" (DRY-RUN: ${action} → ${executed_action})"
  fi
  if [[ "$force" == "true" ]]; then
    suffix="${suffix} [FORCED]"
  fi
  echo "✓ ${id}${suffix}" >&2

  if $no_wait; then
    printf '%s' "$submit" | "$_ZOA_JQ" .
    return 0
  fi

  local result
  result=$(_zoa_poll "$id")
  local rc=$?
  printf "\r\033[K" >&2

  local exec_status output_status runner_s upload_s total_s
  exec_status=$(printf '%s' "$result" | "$_ZOA_JQ" -r '.status // empty')
  output_status=$(printf '%s' "$result" | "$_ZOA_JQ" -r '.output_status // "pending"')
  runner_s=$(printf '%s' "$result" | "$_ZOA_JQ" -r '.runner_seconds // 0')
  upload_s=$(printf '%s' "$result" | "$_ZOA_JQ" -r '.upload_seconds // 0')
  total_s=$(printf '%s' "$result" | "$_ZOA_JQ" -r '.duration_seconds // 0')
  local dispatch_s=$((total_s - runner_s - upload_s))

  local timing="total=${total_s}s (runner=${runner_s}s upload=${upload_s}s dispatch=${dispatch_s}s)"

  if [[ "$exec_status" == "succeeded" ]]; then
    if [[ "$output_status" == "uploaded" ]]; then
      echo "✓ completed (${timing})" >&2
      local output
      output=$(_zoa_request GET "/trusted-actions/runs/${id}?include=output")
      printf '%s' "$output" | "$_ZOA_JQ" -r '.output // empty'
    elif [[ "$output_status" == "failed" ]]; then
      echo "✓ completed (${timing}) ⚠ output upload failed" >&2
      return 0
    else
      echo "✓ completed (${total_s}s)" >&2
      return 0
    fi
  else
    if [[ "$output_status" == "uploaded" ]]; then
      echo "✗ ${exec_status} (${timing})" >&2
      local logs
      logs=$(_zoa_request GET "/trusted-actions/runs/${id}?include=logs")
      printf '%s' "$logs" | "$_ZOA_JQ" -r '.logs // .output // empty'
    else
      echo "✗ ${exec_status} (${total_s}s) ⚠ output upload failed" >&2
    fi
    return 1
  fi
}

_zoa_get() {
  local id="${1:-}"
  [[ -z "$id" ]] && { echo "error: usage: zoa get <id> [--output|--logs|--all] [-o json]" >&2; return 1; }
  shift

  local include="" format="human"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)  include="output"; shift ;;
      --logs)    include="logs"; shift ;;
      --all)     include="output,logs"; shift ;;
      -o)        format="$2"; shift 2 ;;
      *) echo "error: unknown flag '$1'" >&2; return 1 ;;
    esac
  done

  local path="/trusted-actions/runs/${id}"
  [[ -n "$include" ]] && path="${path}?include=${include}"

  local resp
  resp=$(_zoa_request GET "$path")

  if [[ "$format" == "json" ]]; then
    printf '%s' "$resp" | "$_ZOA_JQ" .
    return
  fi

  if [[ -z "$include" ]]; then
    printf '%s' "$resp" | "$_ZOA_JQ" -r '
      "ID:        \(.id)",
      "ACTION:    \(.action)\(if .dry_run then " (dry-run → \(.executed_action))" else "" end)",
      "TARGET:    \(.target_cluster)",
      "STATUS:    \(.status)",
      "OUTPUT:    \(.output_status // "pending")",
      "DRY-RUN:   \(if .dry_run then "yes" else "no" end)",
      "FORCE:     \(if .force then "yes" else "no" end)",
      "JIRA:      \(.jira // "-")",
      "OPERATOR:  \(.operator // "-")",
      "PARAMS:    \(.params // {} | to_entries | map(.key + "=" + .value) | join(" ") | if . == "" then "-" else . end)",
      "CREATED:   \(.created_at)",
      "UPDATED:   \(.updated_at // "-")",
      "COMPLETED: \(.completed_at // "-")",
      "DURATION:  \(if .duration_seconds then "\(.duration_seconds)s (runner=\(.runner_seconds // 0)s upload=\(.upload_seconds // 0)s)" else "-" end)"
    '
    return
  fi

  local output_status
  output_status=$(printf '%s' "$resp" | "$_ZOA_JQ" -r '.output_status // "pending"')

  if [[ "$output_status" == "failed" ]]; then
    echo "⚠ output upload failed — no artifacts available" >&2
    printf '%s' "$resp" | "$_ZOA_JQ" -r '"STATUS: \(.status)  OUTPUT: \(.output_status)"'
    return 0
  fi

  printf '%s' "$resp" | "$_ZOA_JQ" -r '
    "ID:        \(.id)",
    "ACTION:    \(.action)\(if .dry_run then " [DRY-RUN → \(.executed_action)]" else "" end)\(if .force then " [FORCED]" else "" end)  TARGET: \(.target_cluster)  STATUS: \(.status)",
    "DURATION:  \(if .duration_seconds then "\(.duration_seconds)s" else "-" end)  OPERATOR: \(.operator // "-")  JIRA: \(.jira // "-")",
    "---"
  '
  if [[ "$include" == *output* ]]; then
    printf '%s' "$resp" | "$_ZOA_JQ" -r '.output // empty'
  fi
  if [[ "$include" == *logs* ]]; then
    printf '%s' "$resp" | "$_ZOA_JQ" -r '.logs // empty'
  fi
}

_zoa_logs() {
  local id="${1:-}"
  [[ -z "$id" ]] && { echo "error: usage: zoa logs <id>" >&2; return 1; }

  _zoa_request GET "/trusted-actions/runs/${id}?include=logs" | "$_ZOA_JQ" -r '.logs // empty'
}

_zoa_runs() {
  local query="" format="human"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--target)   query="${query:+${query}&}target=$2"; shift 2 ;;
      --status)      query="${query:+${query}&}status=$2"; shift 2 ;;
      --action)      query="${query:+${query}&}action=$2"; shift 2 ;;
      --operator)    query="${query:+${query}&}operator=$2"; shift 2 ;;
      --scope)       query="${query:+${query}&}scope=$2"; shift 2 ;;
      --type)        query="${query:+${query}&}type=$2"; shift 2 ;;
      --output-status) query="${query:+${query}&}output_status=$2"; shift 2 ;;
      --dry-run)     query="${query:+${query}&}dry_run=true"; shift ;;
      --force)       query="${query:+${query}&}force=true"; shift ;;
      --since)       query="${query:+${query}&}since=$2"; shift 2 ;;
      --limit)       query="${query:+${query}&}limit=$2"; shift 2 ;;
      -o)            format="$2"; shift 2 ;;
      *) echo "error: unknown flag '$1'" >&2; return 1 ;;
    esac
  done

  local path="/trusted-actions/runs"
  [[ -n "$query" ]] && path="${path}?${query}"

  local result
  result=$(_zoa_request GET "$path")

  if [[ "$format" == "json" ]]; then
    printf '%s' "$result" | "$_ZOA_JQ" .
    return
  fi

  printf '%s' "$result" | "$_ZOA_JQ" -r '
    def fmt_dur(s): if s == null or s == 0 then "-" elif s < 60 then "\(s)s" elif s < 3600 then "\(s/60|floor)m\(s%60)s" else "\(s/3600|floor)h\(s%3600/60|floor)m" end;
    def fmt_ts(iso): if iso == null or iso == "" then "-" else (iso | split("T") | .[0] + " " + .[1][:8]) end;
    def fmt_params(p): if p == null or p == {} then "-" else [p | to_entries[] | "\(.key)=\(.value)"] | join(",") | if length > 30 then .[:29] + "…" else . end end;
    def fmt_action: "\(.action)\(if .dry_run then " [DRY]" else "" end)\(if .force then " [FRC]" else "" end)";
    (.items // []) | if length == 0 then empty else
      .[] | [
        .id,
        fmt_action,
        .scope,
        (.type // "-"),
        (.target_cluster // "-"),
        .status,
        (.output_status // "-"),
        fmt_dur(.runner_seconds),
        fmt_dur(.upload_seconds),
        fmt_dur(.duration_seconds),
        fmt_params(.params),
        (.operator // "-"),
        fmt_ts(.created_at)
      ] | @tsv
    end
  ' | {
    printf "%-38s %-18s %-9s %-6s %-22s %-10s %-9s %-5s %-5s %-5s %-35s %-12s %s\n" \
      "ID" "ACTION" "SCOPE" "TYPE" "TARGET" "STATUS" "OUTPUT" "RUN" "UPL" "TOT" "PARAMS" "OPERATOR" "CREATED"
    while IFS=$'\t' read -r _id _action _scope _type _target _status _output _run _upl _total _params _operator _created; do
      printf "%-38s %-18s %-9s %-6s %-22s %-10s %-9s %-5s %-5s %-5s %-35s %-12s %s\n" \
        "$_id" "$_action" "$_scope" "$_type" "$_target" "$_status" "$_output" "$_run" "$_upl" "$_total" "$_params" "$_operator" "$_created"
    done
  } || echo "No executions found"
}

_zoa_audit() {
  local query="" format="human"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--target)   query="${query:+${query}&}target=$2"; shift 2 ;;
      --action)      query="${query:+${query}&}action=$2"; shift 2 ;;
      --operator)    query="${query:+${query}&}operator=$2"; shift 2 ;;
      --method)      query="${query:+${query}&}method=$2"; shift 2 ;;
      --since)       query="${query:+${query}&}since=$2"; shift 2 ;;
      --limit)       query="${query:+${query}&}limit=$2"; shift 2 ;;
      -o)            format="$2"; shift 2 ;;
      *) echo "error: unknown flag '$1'" >&2; return 1 ;;
    esac
  done

  local path="/trusted-actions/audit"
  [[ -n "$query" ]] && path="${path}?${query}"

  local resp
  resp=$(_zoa_request GET "$path")

  local err_code
  err_code=$(printf '%s' "$resp" | "$_ZOA_JQ" -r '.code // empty')
  if [[ -n "$err_code" ]]; then
    printf '%s' "$resp" | "$_ZOA_JQ" -r '"error: \(.reason // .code)"'
    return 1
  fi

  if [[ "$format" == "json" ]]; then
    printf '%s' "$resp" | "$_ZOA_JQ" .
    return
  fi

  local count
  count=$(printf '%s' "$resp" | "$_ZOA_JQ" -r '(.items // []) | length')
  if [[ "$count" == "0" ]]; then
    echo "No audit entries found"
    return
  fi

  printf "%-9s %-5s %-5s %-12s %-20s %-14s %-10s %s\n" \
    "TIME" "METH" "CODE" "OPERATOR" "TARGET" "JIRA" "EXEC_ID" "PATH"
  printf '%s' "$resp" | "$_ZOA_JQ" -r '
    def dash(v): if v == "" or v == null then "-" else v end;
    (.items // [])[] | [.timestamp, .method, (.status_code | tostring), .operator, dash(.target_cluster), dash(.jira), dash(.execution_id), .path] | @tsv
  ' | \
  while IFS=$'\t' read -r ts method scode op target jira execid apath; do
    local short_ts="${ts:11:8}"
    local short_exec="${execid:0:8}"
    [[ "$short_exec" == "-" ]] && short_exec=""
    local short_path="${apath#/api/v0/trusted-actions/}"
    printf "%-9s %-5s %-5s %-12s %-20s %-14s %-10s %s\n" \
      "$short_ts" "$method" "$scode" "$op" "$target" "$jira" "$short_exec" "$short_path"
  done
}

_zoa_actions() {
  local action="" format="human"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o)     format="$2"; shift 2 ;;
      *)      action="$1"; shift ;;
    esac
  done

  if [[ -n "$action" ]]; then
    _zoa_request GET "/trusted-actions/${action}" | "$_ZOA_JQ" .
    return
  fi

  local resp
  resp=$(_zoa_request GET "/trusted-actions")

  if [[ "$format" == "json" ]]; then
    printf '%s' "$resp" | "$_ZOA_JQ" .
    return
  fi

  printf "%-25s %-10s %-10s %s\n" "NAME" "SCOPE" "TYPE" "DESCRIPTION"
  printf '%s' "$resp" | "$_ZOA_JQ" -r '(.items // [])[] | [.name, .scope, .type, .description] | @tsv' | \
    while IFS=$'\t' read -r name scope type desc; do
      printf "%-25s %-10s %-10s %s\n" "$name" "$scope" "$type" "$desc"
    done
}

_zoa_describe() {
  local action="${1:-}" format="human"
  [[ -z "$action" ]] && { echo "error: usage: zoa describe <action> [-o json]" >&2; return 1; }
  shift 2>/dev/null || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o) format="$2"; shift 2 ;;
      *) echo "error: unknown flag '$1'" >&2; return 1 ;;
    esac
  done

  local resp
  resp=$(_zoa_request GET "/trusted-actions/${action}")

  if [[ "$format" == "json" ]]; then
    printf '%s' "$resp" | "$_ZOA_JQ" .
  else
    printf '%s' "$resp" | "$_ZOA_JQ" -r '
      "NAME:        \(.name)",
      "SCOPE:       \(.scope)",
      "TYPE:        \(.type)",
      "DESCRIPTION: \(.description)",
      "APPROVAL:    \(if .authorization.approval == "none" then "none" elif .authorization.approval then "required" else "none" end)",
      (if .write_cooldown_seconds > 0 then "COOLDOWN:    \(.write_cooldown_seconds)s" else empty end),
      (if .dry_run_action then "DRY-RUN:     \(.dry_run_action)" else empty end),
      "",
      "REQUIRED FIELDS:",
      (if (.required_fields | length) > 0 then (.required_fields[] | "  \(.)") else "  target_cluster, jira" end),
      "",
      "PARAMETERS:",
      (if (.params | length) == 0 then "  (none)" else (.params[] | "  \(.name)\(if .required then " *" else "" end)\t\(.description // "")\(if .default and .default != "" then " [default: \(.default)]" else "" end)") end)
    '
  fi
}

_zoa_help() {
  cat <<'EOF'
ZOA — Zero Operator Access CLI

Usage: zoa <command> [args]

Commands:
  run <action> -t <cluster> [flags]   Execute a trusted action (waits for result)
  get <id> [--output|--logs|--all]    Retrieve execution details
  logs <id>                           Show execution log (raw)
  runs [filters]                      List recent executions
  audit [filters]                     View audit log of API calls
  actions [<action>]                  List TAs, or describe one (alias for describe)
  describe <action>                   Show TA parameters and metadata

Global flags:
  -o json                             Output raw JSON instead of human format

Run flags:
  -t, --target <cluster>   Target cluster (required)
  --jira <ticket>          Jira ticket (required, e.g. ROSAENG-1234)
  -n <namespace>           Namespace
  -A                       All namespaces
  -l <selector>            Label selector
  -v, --verbose            Full JSON output (no compact)
  --name <name>            Resource name
  --force                  Bypass write cooldown and max concurrent
  --dry-run                Execute dry_run_action instead (preview)
  --no-wait                Don't wait for completion (print ID only)
  --param key=value        Pass arbitrary param

Runs filters (all combinable):
  -t, --target <cluster>   Filter by target cluster
  --status <status>        Filter by status (pending|running|succeeded|failed|timed_out)
  --output-status <s>      Filter by output status (pending|uploaded|failed)
  --action <name>          Filter by action name
  --operator <name>        Filter by operator
  --scope <scope>          Filter by scope (kube-api|aws)
  --type <type>            Filter by type (read|write)
  --dry-run                Show only dry-run executions
  --force                  Show only forced executions
  --since <duration>       Filter by time (e.g. 1h, 24h, 7d)
  --limit <n>              Max results (default 20, max 100)
  --json                   Raw JSON output (pipeable to jq)

Get flags:
  --logs                   Show logs instead of output
  --all                    Show output + logs + metadata
  --info                   Show metadata only (status, timing)
  -o, --output             Output only (no metadata envelope, pipeable)
  --json                   Raw JSON output

Audit filters (all combinable):
  -t, --target <cluster>   Filter by target cluster
  --action <name>          Filter by action name
  --operator <name>        Filter by operator
  --method <method>        Filter by HTTP method (GET|POST)
  --since <duration>       Filter by time (e.g. 1h, 24h, 7d)
  --limit <n>              Max results (default 50, max 200)
  --json                   Raw JSON output

Environment:
  ZOA_API                  API Gateway URL (required)
  AWS_ACCESS_KEY_ID        AWS credentials (required)
  AWS_SECRET_ACCESS_KEY    AWS credentials (required)
  AWS_SESSION_TOKEN        AWS session token (required for assumed roles)

Examples:
  # Run actions (--jira is required for all TAs)
  zoa run get_nodes -t mc-useast1-1 --jira ROSAENG-1234
  zoa run get_pods -t mc-useast1-1 -n maestro -l app=maestro --jira ROSAENG-1234
  zoa run get_pods -t mc-useast1-1 -A --jira ROSAENG-1234 | jq '.[] | select(.status != "Running")'
  zoa run get_deployments -t mc-useast1-1 -n openshift-monitoring -v --jira ROSAENG-1234
  zoa run get_events -t mc-useast1-1 -n maestro --param field_selector=reason=BackOff --jira ROSAENG-1234
  zoa run get_resource -t mc-useast1-1 --resource deployments -A --jira ROSAENG-1234
  zoa run rollout_restart -t mc-useast1-1 -n maestro --name maestro --jira ROSAENG-1234
  zoa run delete_pod -t mc-useast1-1 -n maestro --name maestro-agent-xyz --jira ROSAENG-1234
  zoa run delete_pod -t mc-useast1-1 -n maestro --name maestro-agent-xyz --jira ROSAENG-1234 --dry-run
  zoa run rollout_restart -t mc-useast1-1 -n maestro --name maestro --jira ROSAENG-1234 --force

  # Retrieve results
  zoa get fa65418c-f4eb-4f5c-8314-baaeb695ba7d
  zoa get fa65418c-f4eb-4f5c-8314-baaeb695ba7d --logs
  zoa get fa65418c-f4eb-4f5c-8314-baaeb695ba7d --all
  zoa get fa65418c-f4eb-4f5c-8314-baaeb695ba7d --info

  # View logs
  zoa logs fa65418c-f4eb-4f5c-8314-baaeb695ba7d

  # History with filters (all combinable)
  zoa runs -t eph-bc5fee45-mc01
  zoa runs -t eph-bc5fee45-mc01 --since 1h
  zoa runs --status failed --since 24h
  zoa runs --output-status failed --since 7d
  zoa runs --action get_pods --operator slopezma --since 7d
  zoa runs --type write --since 12h
  zoa runs --scope kube-api --status succeeded --limit 50
  zoa runs --dry-run --since 24h
  zoa runs --force --since 7d
  zoa runs --json | jq '.items[] | select(.runner_seconds > 10)'

  # Audit log
  zoa audit --since 24h
  zoa audit --operator slopezma --since 7d
  zoa audit --action rollout_restart -t mc-useast1-1
  zoa audit --method POST --since 1h
  zoa audit --json | jq '.items[] | select(.status_code != 202)'

  # Discover available actions
  zoa actions
  zoa actions get_pods              # alias for describe
  zoa describe get_pods
  zoa describe rollout_restart
EOF
}
