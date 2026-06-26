#!/bin/bash
set -euo pipefail

REPO="openshift-online/rosa-hyperfleet"
STATE_DIR="${HOME}/.cache/pr-report"
STATE_FILE="${STATE_DIR}/rosa-hyperfleet.json"
REPORT_DIR="${STATE_DIR}/reports"

mkdir -p "$STATE_DIR" "$REPORT_DIR"

DATESTAMP=$(date +%Y%m%d)
MD_FILE="${REPORT_DIR}/report-${DATESTAMP}.md"
HTML_FILE="${REPORT_DIR}/report-${DATESTAMP}.html"

echo "Fetching PR data from ${REPO}..." >&2

# Fetch open PRs with full detail
OPEN_PRS=$(gh pr list --repo "$REPO" --state open \
  --json number,title,author,labels,reviewDecision,createdAt,updatedAt,additions,deletions,changedFiles,body,isDraft)

# Fetch recently closed/merged PRs (enough to cover activity since last report)
CLOSED_PRS=$(gh pr list --repo "$REPO" --state closed --limit 15 \
  --json number,title,author,state,createdAt,updatedAt,additions,deletions,changedFiles,labels,body)

# For each open PR, fetch the list of changed file paths (gives Claude
# the best signal for summarizing what the PR actually does)
FILE_DATA="[]"
for pr_num in $(echo "$OPEN_PRS" | jq -r '.[].number'); do
  echo "  Fetching file list for PR #${pr_num}..." >&2
  files=$(gh pr view "$pr_num" --repo "$REPO" --json files --jq '[.files[].path]' 2>/dev/null || echo '[]')
  FILE_DATA=$(echo "$FILE_DATA" | jq --argjson n "$pr_num" --argjson f "$files" \
    '. + [{number: $n, files: $f}]')
done

# Build current snapshot
CURRENT=$(jq -n \
  --argjson open "$OPEN_PRS" \
  --argjson closed "$CLOSED_PRS" \
  --argjson files "$FILE_DATA" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{timestamp: $ts, open: $open, closed: $closed, open_pr_files: $files}')

# Load previous snapshot
PREV="null"
PREV_TS="never"
if [ -f "$STATE_FILE" ]; then
  PREV=$(cat "$STATE_FILE")
  PREV_TS=$(echo "$PREV" | jq -r '.timestamp // "unknown"')
fi

# Save current snapshot as baseline for next run
echo "$CURRENT" >"$STATE_FILE"

echo "Generating report (last report: ${PREV_TS})..." >&2

# Build the prompt in a temp file to avoid ARG_MAX issues with large PR bodies
PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

cat >"$PROMPT_FILE" <<PROMPT_EOF
You are generating a PR status report for the rosa-hyperfleet project.
The GitHub repo is: https://github.com/${REPO}
Today's date is $(date +%Y-%m-%d).

IMPORTANT: Every PR reference (e.g. #70, PR #70) MUST be a markdown link to the PR on GitHub.
Format: [#70](https://github.com/${REPO}/pull/70)
This applies everywhere in the report — headings, tables, inline mentions, all of it.

## REPORT FORMAT

Start the report with:

# ROSA Regional Platform — PR Report
**Generated:** $(date +%Y-%m-%d)  |  **Previous report:** ${PREV_TS}

---

### 1. Open PRs — Big Picture

For each open PR, provide:
- **PR #, title, author** (PR # must link to GitHub)
- **Size**: +additions / -deletions / N files
- **Age**: how long it has been open (calculate from createdAt vs today)
- **Big picture**: This is the most important part. Write 1-2 paragraphs explaining:
  1. What capability or change this PR introduces to the platform and why it matters in the context of the rosa-hyperfleet architecture (regional clusters, management clusters, GitOps, Terraform, etc.)
  2. What areas of the codebase it touches — group the changed files by area (e.g. "Terraform modules", "ArgoCD config", "scripts", "docs") and explain what the changes in each area accomplish together.
  3. Any risks, dependencies, or architectural implications you can infer from the file paths and PR body.
  Do NOT just list files. Synthesize and explain.
- **Status**: review state, labels (WIP, needs-rebase, approved, lgtm), blockers

Use a horizontal rule (---) between each PR.

### 2. What Changed Since Last Report

Previous report timestamp: ${PREV_TS}

Compare the CURRENT and PREVIOUS snapshots and report:
- **New PRs**: PRs in current.open that were NOT in previous.open (link each)
- **Merged/Closed**: PRs that were in previous.open but are no longer (check current.closed for details). For each, give a one-line summary of what it delivered. Link each.
- **Activity on existing PRs**: For PRs open in both snapshots, report if updatedAt changed, if labels changed, if reviewDecision changed. Summarize the nature of the activity.
- **Stale**: PRs open in both snapshots with no changes at all

If previous snapshot is null, say: "First report — no previous data to compare against."

### 3. Attention Items

Present as a markdown table with columns: PR (linked), Title, Issue, Recommendation.
Flag items that need action:
- Unreviewed PRs (no reviewDecision, not WIP)
- Stale PRs (open > 5 days with no recent activity)
- Blocked PRs (needs-rebase, failing checks)
- Large PRs without review

Use markdown throughout.

---

CURRENT SNAPSHOT (just fetched):
${CURRENT}

PREVIOUS SNAPSHOT (from last report):
${PREV}
PROMPT_EOF

# Generate the markdown report
claude -p "$(cat "$PROMPT_FILE")" >"$MD_FILE"

echo "Markdown report saved to: ${MD_FILE}" >&2

# Convert to styled HTML via pandoc
# CSS based on Sakura v1.5.1 (https://github.com/oxalorg/sakura) with table tweaks
CSS_FILE="${STATE_DIR}/report.css"
cat > "$CSS_FILE" <<'CSS_EOF'
html {
  font-size: 62.5%;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", sans-serif;
}
body {
  font-size: 1.8rem;
  line-height: 1.618;
  max-width: 70em;
  margin: auto;
  color: #4a4a4a;
  background-color: #f9f9f9;
  padding: 13px;
}
@media (max-width: 684px) { body { font-size: 1.53rem; } }
@media (max-width: 382px) { body { font-size: 1.35rem; } }
h1, h2, h3, h4, h5, h6 {
  line-height: 1.1;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", sans-serif;
  font-weight: 700;
  margin-top: 3rem;
  margin-bottom: 1.5rem;
  overflow-wrap: break-word;
  word-wrap: break-word;
  word-break: break-word;
}
h1 { font-size: 2.35em; }
h2 { font-size: 2em; }
h3 { font-size: 1.75em; }
h4 { font-size: 1.5em; }
h5 { font-size: 1.25em; }
h6 { font-size: 1em; }
p { margin-top: 0px; margin-bottom: 2.5rem; }
small, sub, sup { font-size: 75%; }
hr { border-color: #1d7484; }
a { text-decoration: none; color: #1d7484; }
a:visited { color: #144f5a; }
a:hover { color: #982c61; border-bottom: 2px solid #4a4a4a; }
ul { padding-left: 1.4em; margin-top: 0px; margin-bottom: 2.5rem; }
li { margin-bottom: 0.4em; }
blockquote {
  margin-left: 0px; margin-right: 0px;
  padding-left: 1em; padding-top: 0.8em; padding-bottom: 0.8em; padding-right: 0.8em;
  border-left: 5px solid #1d7484;
  margin-bottom: 2.5rem;
  background-color: #f1f1f1;
}
blockquote p { margin-bottom: 0; }
img, video { height: auto; max-width: 100%; margin-top: 0px; margin-bottom: 2.5rem; }
pre {
  background-color: #f1f1f1;
  display: block; padding: 1em; overflow-x: auto;
  margin-top: 0px; margin-bottom: 2.5rem; font-size: 0.9em;
}
code, kbd, samp {
  font-size: 0.9em; padding: 0 0.5em;
  background-color: #f1f1f1; white-space: pre-wrap;
}
pre > code { padding: 0; background-color: transparent; white-space: pre; font-size: 1em; }
table {
  text-align: left; width: 100%;
  border-collapse: collapse; margin-bottom: 2rem; table-layout: auto;
}
col { width: auto !important; }
td, th { padding: 0.5em 0.8em; border: 1px solid #d0d0d0; }
th { background-color: #eef3f5; }
tr:nth-child(even) { background-color: #f5f7f8; }
CSS_EOF

pandoc "$MD_FILE" -o "$HTML_FILE" \
  --standalone \
  --metadata title="PR Report — $(date +%Y-%m-%d)" \
  --embed-resources \
  --css="$CSS_FILE"

echo "CSS installed to: ${CSS_FILE}" >&2

echo "HTML report saved to: ${HTML_FILE}" >&2

# Open in Chrome
open -a "Google Chrome" "$HTML_FILE"

echo "Done." >&2
