#!/usr/bin/env bash
# Fetches open PRs labelled "review-ready", "discussion-needed", or "needs-ok-to-test" across all
# ROSA HyperFleet repos and writes dashboard/data.json.
#
# Uses `gh pr list` (not `gh search prs`) so we can include reviewRequests.
#
# Requires: gh (authenticated), jq
# Usage:    ./dashboard/fetch-data.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${SCRIPT_DIR}/data.json"

REPOS=(
  openshift-online/rosa-hyperfleet
  openshift-online/rosa-hyperfleet-api
  openshift-online/rosa-hyperfleet-cli
  openshift-online/rosa-hyperfleet-internal
  openshift-online/rosa-hyperfleet-zoa
  openshift-online/rosa-hyperfleet-kube-applier
  openshift-online/aws-nuke-cf
)

JSON_FIELDS="number,title,author,labels,reviewRequests,createdAt,updatedAt,url"

fetch_label() {
  local label="$1"
  local tmp
  tmp=$(mktemp)
  echo '[]' > "$tmp"

  for repo in "${REPOS[@]}"; do
    local result
    result=$(gh pr list --repo "$repo" --label "$label" --state open \
      --limit 100 --json "$JSON_FIELDS" 2>/dev/null) || result='[]'

    # Inject repository.name into each PR (gh pr list doesn't include it)
    local repo_name="${repo#*/}"
    result=$(echo "$result" | jq --arg name "$repo_name" '[.[] | . + {repository: {name: $name}}]')

    jq -s '.[0] + .[1]' "$tmp" <(echo "$result") > "${tmp}.new" && mv "${tmp}.new" "$tmp"
  done

  cat "$tmp"
  rm -f "$tmp"
}

echo "Fetching review-ready PRs..."
fetch_label "review-ready" > /tmp/rr.json

echo "Fetching discussion-needed PRs..."
fetch_label "discussion-needed" > /tmp/dn.json

BOT_AUTHORS="app/dependabot|app/red-hat-konflux-kflux-prd-rh02|redhat-chai-bot"

echo "Fetching needs-ok-to-test PRs (bot authors only)..."
fetch_label "needs-ok-to-test" | jq --arg bots "$BOT_AUTHORS" \
  '[.[] | select(.author.login | test($bots))]' > /tmp/okt.json

jq -n \
  --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile rr /tmp/rr.json \
  --slurpfile dn /tmp/dn.json \
  --slurpfile okt /tmp/okt.json \
  '{updated: $updated, review_ready: $rr[0], discussion_needed: $dn[0], needs_ok_to_test: $okt[0]}' \
  > "$OUT"

echo "Wrote $OUT ($(jq '.review_ready | length' "$OUT") review-ready, $(jq '.discussion_needed | length' "$OUT") discussion-needed, $(jq '.needs_ok_to_test | length' "$OUT") needs-ok-to-test)"
