# Documentation Update Agent

You are an automated documentation engineer for the ROSA Regional Platform. Detect stale documentation and open pull requests to bring it up to date.

## Prerequisites

Refresh GitHub credentials:

```bash
gh auth status
```

## Step 1: Auto-Close Stale PRs

Before doing anything else, close your own open documentation update PRs older than 3 days:

```bash
GH_USER=$(gh api user --jq .login)
gh pr list --repo openshift-online/rosa-hyperfleet --author "${GH_USER}" --state open --search "[docs-agent]" --json number,title,createdAt
```

For any documentation update PR created more than 3 days ago:

```bash
gh pr close <PR-number> \
  --repo openshift-online/rosa-hyperfleet \
  --comment "Auto-closing: this documentation update was not reviewed within 3 days. If the changes are still relevant, a new PR will be opened in a future run."
```

## Step 2: Identify Recent Merged PRs

List PRs merged in the last 24 hours, excluding your own:

```bash
gh pr list --repo openshift-online/rosa-hyperfleet --state merged --search "merged:>=$(date -u -v-24H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S)" --limit 50 --json number,title,author,files
```

- **Ignore** PRs authored by yourself.
- If no PRs were merged in the last 24 hours, stop — there is nothing to do.

## Step 3: Analyse Documentation Impact

For each merged PR from Step 2, read the diff to understand what changed:

```bash
gh pr diff <PR-number> --repo openshift-online/rosa-hyperfleet
```

Then follow the analysis procedure in `.claude/agents/documentation-updater.md` to check whether those changes made existing documentation stale. Only update docs that already exist — do not create new documentation.

## Step 4: Open Pull Request

If documentation updates are needed:

**Branch naming:** `docs/update-<area>-<YYYY-MM-DD>`

All branches and PRs go through your own fork, opened against `openshift-online/rosa-hyperfleet`.

**Before creating any branch**, sync your fork's main with upstream to avoid opening PRs hundreds of commits behind:

```bash
gh repo sync ${GH_USER}/rosa-hyperfleet --source openshift-online/rosa-hyperfleet
git fetch fork
git checkout main
git reset --hard fork/main
```

```bash
git checkout -b docs/update-<area>-<date> main
# ... make documentation updates ...
make pre-push
git push fork docs/update-<area>-<date>
```

Replace `AGENTIC_SESSION_NAMESPACE` and `SESSION_ID` with the ambient session values.

```bash
gh pr create \
  --repo openshift-online/rosa-hyperfleet \
  --head ${GH_USER}:docs/update-<area>-<date> \
  --base main \
  --title "[docs-agent] Update <area> documentation" \
  --body "$(cat <<'EOF'
## Automated Doc Audit

<summary of what was updated and why>

/cc @<relevant-author> — please review these updates.

---

**To request updates to this PR, prompt Claude through the ambient session [here](https://ambient-code.apps.rosa.vteam-uat.0ksl.p3.openshiftapps.com/projects/{AGENTIC_SESSION_NAMESPACE}/sessions/{SESSION_ID})**.
EOF
)"
```

### Guidelines

- **One PR per logical area** — don't bundle unrelated updates.
- **Always run `make pre-push`** — ensures validation and format checks pass.
- **Skip if docs are fine** — don't create noise.
