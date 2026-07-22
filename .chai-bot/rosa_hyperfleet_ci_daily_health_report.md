# Scheduled report: ROSA HyperFleet CI daily health report

You are running a **cron** scheduled task that produces a daily CI health report for ROSA HyperFleet jobs. Keep the report **as concise as possible** to minimize channel noise. When everything is healthy, keep the summary concise, but still use the standard report structure. Only expand into detail when something needs attention.

## Goal

Check the pass/fail history (last 10 completed builds per job) for ROSA HyperFleet CI periodic jobs. Report overall CI health and individual job status.

- Always post the top-level status to the channel (never call `no_action_required()`)
- If all jobs are passing: post the status summary only — no threaded replies
- If any job is failing: post the status summary, then create a threaded reply per failing job with investigation

## Procedure

### 1. Load job configuration

Fetch the CI configuration from the single source of truth:
`https://raw.githubusercontent.com/openshift/release/refs/heads/main/ci-operator/config/openshift-online/rosa-hyperfleet/openshift-online-rosa-hyperfleet-main.yaml`

Use `fetch_web_content` to retrieve this YAML file. It defines all tests including periodic jobs with `cron:` schedules.

**Track these 2 periodic jobs:**

- `nightly-ephemeral` (test name `as: nightly-ephemeral`)
- `nightly-integration` (test name `as: nightly-integration`)

The full Prow job names follow the pattern:
`periodic-ci-openshift-online-rosa-hyperfleet-main-{test-name}`

If the fetch fails, fall back to these job names:

- periodic-ci-openshift-online-rosa-hyperfleet-main-nightly-ephemeral
- periodic-ci-openshift-online-rosa-hyperfleet-main-nightly-integration

### 2. Collect build history (last 10 runs)

For each job, collect the **last 10 completed job runs** for the trend table. Use Prow CI tools (`search_prow_jobs`, `query_prowjobs`, etc.) or `fetch_web_content` on the job-history page.

**Same-day reporting rule:** The "Latest Run Status" section must report **today's run** for each job. Do not fall back to a previous day's completed run for the latest status. Both jobs must be reported from the same day (today).

**Job status values:** Report the actual state of today's run:

- **passing** — today's run completed successfully
- **failing** — today's run completed with failures
- **running** — today's run is currently in progress
- **scheduled** — today's run is queued but not yet started
- **no run today** — no run was triggered today

**Retry for in-progress jobs:** If today's run for any tracked job is in a `scheduled` or `running` state:

1. Wait **10 minutes** and re-check the job status
2. Repeat up to **3 times** (30 minutes maximum wait)
3. After 30 minutes, report the current state as-is (e.g., "running" if still in progress)

**Important:** Track each of the last 10 runs with their dates:

- For each run, record: date, pass/fail status, build ID
- Format date as "MonDD" (e.g., "Jun10", "Jun11", "Jun19")
- Runs are ordered: oldest run first → newest run last (left to right)
- Count total: how many of the 10 runs passed vs failed
- Example: If 7 passed and 3 failed → "7/10 (70%)"

If Prow tools don't return historical build data directly, use `fetch_web_content` to retrieve the job-history page at `https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/%JOB_NAME%`. The HTML contains `var allBuilds = [{ID, Result, Started, Duration}];`.

### 3. Compute pass rates and health status

**Per-job pass rate**: pass/total for last 10 runs (e.g., 7/10 = 70%).

**10-run trend table**: Create a table with dates as header and jobs as rows:

- **Header row**: Dates in MonDD format (e.g., Jun10, Jun11, Jun12, ...)
- **Job rows**: Job name followed by ✅ or ❌ for each run, then pass count and percentage
- Order: oldest run first (leftmost) → newest run last (rightmost)
- Use monospace formatting for alignment

**Table format example:**

```text
              Jun10 Jun11 Jun12 Jun13 Jun14 Jun15 Jun16 Jun17 Jun18 Jun19
ephemeral:     ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   10/10 (100%)
integration:   ✅    ✅    ❌    ✅    ✅    ✅    ✅    ✅    ❌    ❌    7/10 (70%)
```

**Overall CI health** (based on today's run status for each job):

- :large_green_circle: Both jobs passing (2/2) - both today's runs completed successfully
- :large_yellow_circle: Mixed status (1/2) - one passing, one failing/running/scheduled
- :red_circle: Both jobs failing (0/2) - both today's runs failed
- :hourglass_flowing_sand: Pending — one or both jobs still running/scheduled (after retries exhausted)
- :white_circle: No runs today — no runs were triggered today for either job

**Individual job health** (based on today's run):

- :large_green_circle: Today's run passed
- :red_circle: Today's run failed
- :hourglass_flowing_sand: Today's run is still running or scheduled (after retries exhausted)
- :white_circle: No run triggered today

### 4. Channel response (top-level summary)

Post a concise summary as your channel response. Use concise job names: "ephemeral" and "integration".

**Emoji key:** :large_green_circle: passing, :red_circle: failing, :large_yellow_circle: mixed, :hourglass_flowing_sand: running/scheduled, :white_circle: no run today.

```text
%OVERALL_EMOJI% *CI Daily — %DATE%*
%JOB_EMOJI% ephemeral: %STATUS% (<%URL%|run>)  |  %JOB_EMOJI% integration: %STATUS% (<%URL%|run>)

              Jun10 Jun11 Jun12 Jun13 Jun14 Jun15 Jun16 Jun17 Jun18 Jun19
ephemeral:     ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   10/10 (100%)
integration:   ✅    ✅    ❌    ✅    ✅    ✅    ✅    ✅    ❌    ❌    7/10 (70%)
```

Use monospace/code block formatting for the trend table. Align columns for readability.

### 5. Failure analysis (threaded replies — only when jobs are failing)

**Skip this step entirely if both jobs are passing.** Only create threaded replies when a job has failed.

After your top-level summary (Step 4), emit `---THREAD_DETAILS---` on its own line. Everything after that delimiter becomes threaded replies (not part of the channel summary). Separate each threaded reply with `---THREAD_BREAK---` on its own line.

For each job whose **latest run failed**, produce a **separate threaded reply** with investigation. Follow the investigation procedure in `.claude/agents/ci-troubleshooter.md` to diagnose the failure. The source is `main` — read files directly with the Read tool.

**For every failure, perform ALL THREE analysis steps before classifying. Do not classify as Flake without completing all three.** Unclear is permitted when S3 logs cannot be obtained, but only with a documented error and evidence gap.

1. **Prow artifact analysis** (Step 5 in ci-troubleshooter) — fetch and analyze the build logs and artifacts from GCS. Identify the failing step, error messages, and failure scope.

2. **S3 log extraction and analysis** (Step 5b in ci-troubleshooter) — **MANDATORY.** Always download and extract tar.gz archives to a local workspace directory. Perform broad grep-based analysis across all namespaces, not just the suspected ones. Follow the broad S3 log analysis procedure in the ci-troubleshooter agent.
   - Use the AWS profiles matching the failing job:
     - Ephemeral jobs (`nightly-ephemeral`): `chai-rc-ci` for RC, `chai-mc-ci` for MC
     - Integration jobs (`nightly-integration`): `chai-rc-int` for RC, `chai-mc-int` for MC
   - Fetch scope based on Prow analysis: RC-only, MC + RC, or both if unclear
   - If S3 logs are inaccessible, report the specific error — classification ceiling becomes Unclear

3. **Git commit correlation** (Step 5c in ci-troubleshooter) — **MANDATORY.** Identify the last passing run, find all commits between last-good and current-bad, and examine commits touching the failing component. Also check `rosa-hyperfleet-api` for API/CLM failures.

**S3 log handling:** Always extract tar.gz locally for full analysis. Clean up downloaded files immediately after analysis is complete — never leave S3 logs on disk between runs. See Step 5b in `.claude/agents/ci-troubleshooter.md` for the full procedure.

Format each threaded reply like:

```text
%EMOJI% *%JOB_NAME% -- %PASS%/10 (%RATE%%)*

%CLASSIFICATION%: %SHORT_SUMMARY%
Evidence: Prow ✅ | S3 Logs ✅/❌ | Git History ✅/❌ | Trend ✅
%ROOT_CAUSE_ANALYSIS%
S3 Log Evidence: %KEY_FINDINGS_FROM_S3_LOGS%
Suspect Commits: %COMMITS_BETWEEN_LAST_GOOD_AND_CURRENT_BAD% (or "None — no relevant changes")
%CROSS_DAY_ANALYSIS% (if consecutive failures)

Most recent failure: <%JOB_RUN_URL%|Build #%NUMBER%> (%DATE%)
%CONSECUTIVE_STREAK% (if applicable)
%FIX_PR_LINK% (if PR raised or updated)
```

Use concise job names: "ephemeral" or "integration".

### 5a. Classify failure — genuine first

For each failing job, classify the failure following Step 7 in `.claude/agents/ci-troubleshooter.md`. **The default assumption is Genuine until evidence proves otherwise.** Aim for Genuine classification wherever evidence supports it.

- **🔧 Genuine** (default) — configuration or code issue, fix PR required
- **🔀 Flake** — transient/intermittent, no code fix needed. **Requires strong justification.**
- **⚠️ Unclear** — last resort when evidence is genuinely contradictory or S3 logs could not be obtained

**Evidence requirements:** Every classification MUST cite evidence from all three sources:

1. **Prow artifacts** — what error was found in the build logs
2. **S3 logs** — what the extracted cluster logs show (healthy pods, error patterns, restarts)
3. **Git history** — whether suspect commits exist between last-good and current-bad runs

If any source was not analyzed, the classification must explain why and acknowledge the evidence gap. A classification of Flake without S3 log and git history evidence is not valid. Unclear is permitted when S3 or git evidence could not be obtained, provided the specific access error and resulting evidence gap are documented.

Use the 10-run trend table and consecutive failure streak as additional signal. Two or more consecutive failures with the same error signature is almost certainly genuine. A single isolated failure with S3 logs showing healthy state AND no suspect commits AND a known transient error pattern may be a flake.

### 5b. Consecutive failure analysis

When a job has failed on **2 or more consecutive days**, do not analyze today's failure in isolation:

1. Compare today's failure with the previous day(s) — are the error signatures the same or different?
2. If **same root cause**: note the streak length and reinforce the diagnosis with accumulated evidence.
3. If **root cause shifted**: clearly state the change. This triggers PR lifecycle management (see 5c).

Include the cross-day comparison in the threaded reply so readers understand the trend without checking previous reports.

### 5c. Actions per classification

Follow Step 10 in `.claude/agents/ci-troubleshooter.md` for the full procedure. The action differs by classification:

**🔧 Genuine — raise PR directly:**

1. **First genuine failure**: share root cause, raise a PR with the fix against the appropriate repo (`rosa-hyperfleet`, `rosa-hyperfleet-api`, or `rosa-hyperfleet-cli`). Branch name: `chai-bot/fix-<job>-<short-description>`. Label: `chai-bot`.
2. **Continued genuine failure (same root cause)**: find the existing open chai-bot PR and add a comment with today's failure URL and any new evidence. Do not create a duplicate PR.
3. **Root cause shifted**: close the existing PR with a comment explaining the root cause change. Open a new PR targeting the updated root cause.

**🔀 Flake — share proposed fix, ask team:**

1. Share the root cause analysis and describe the proposed fix (what file, what change).
2. Ask the team in the thread whether to raise a PR:
   ```
   This appears to be a flake — proposed fix: <summary of change>.
   Should I raise a PR for this? Reply in this thread to confirm.
   ```
3. If the team confirms in the thread, raise the PR. Otherwise skip.
4. If a flake recurs consecutively with the same error, reclassify as Genuine and raise a PR.

**⚠️ Unclear — share analysis, request manual investigation:**

1. Share everything that was checked: Prow artifacts examined, S3 logs fetched (or why they weren't available), error messages found, components inspected.
2. Explain **why** the classification is unclear — e.g., first occurrence with no matching pattern, ambiguous error, insufficient log data.
3. Share the **likely root cause** (best guess) even if confidence is low.
4. Ask the team to investigate manually in the thread:
   ```
   ⚠️ Unable to determine root cause with confidence. Likely cause: <best guess>.
   This needs manual investigation. Please share findings in this thread —
   learnings will be incorporated into future CI analysis.
   ```
5. If the team investigates and shares findings in the thread, offer to turn those learnings into a PR that updates `.claude/agents/ci-troubleshooter.md`. Post a **single** message in the thread — do not repeat the offer or follow up if there's no response:
   ```
   Based on the findings shared here, I can update the CI troubleshooter to recognize this pattern in future runs.
   Should I raise a PR for that? (updates .claude/agents/ci-troubleshooter.md)
   ```
   If approved, raise a PR. If no response or declined, skip — the team can always update the agent manually.
6. If an Unclear failure becomes Genuine after consecutive runs or team input, raise a PR at that point.

Always check for existing chai-bot PRs before creating a new one:

```bash
gh pr list --author @me --label chai-bot --state open --search "<job-name> in:title"
```

Include the PR link, team prompt, or investigation request in the threaded reply as appropriate.

**Example — genuine (PR raised):**

```text
:large_yellow_circle: *CI Daily — Jun 30*
:large_green_circle: ephemeral: passing (<url|run>)  |  :red_circle: integration: failing (<url|run>)

              Jun21 Jun22 Jun23 Jun24 Jun25 Jun26 Jun27 Jun28 Jun29 Jun30
ephemeral:     ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   10/10 (100%)
integration:   ✅    ✅    ❌    ✅    ✅    ✅    ✅    ✅    ❌    ❌    7/10 (70%)

---THREAD_DETAILS---

:red_circle: *integration -- 7/10 (70%)*

🔧 *Genuine* — E2E test `TestClusterCreation` timed out waiting for hosted cluster to become ready.
Evidence: Prow ✅ | S3 Logs ✅ | Git History ✅ | Trend ✅
Root cause: MC maestro-agent pod in CrashLoopBackOff due to MQTT connection failure — incorrect broker endpoint in ArgoCD values.
S3 Log Evidence: `maestro-agent/pods/agent-xyz/agent/logs/current.log` — 47x `CONNACK refused: not authorized`; pod status: CrashLoopBackOff
Suspect Commits: `a1b2c3d` — `feat(argocd): update maestro broker endpoint` — touches `argocd/config/management-cluster/maestro/`
Consecutive failures (2 days): same root cause as Jun 29 — maestro CONNACK failure with identical error signature.

Most recent failure: <url|Build #1234> (Jun 30)
Failing since: Jun 29 (2 consecutive days)
Fix PR: <https://github.com/openshift-online/rosa-hyperfleet/pull/700|#700> (updated with today's evidence)
```

**Example — flake (ask team):**

```text
:red_circle: *ephemeral -- 9/10 (90%)*

🔀 *Flake* — provision-ephemeral timed out waiting for EKS API response.
Evidence: Prow ✅ | S3 Logs ✅ | Git History ✅ | Trend ✅
Single occurrence; Jun 29 and prior runs all passed. Error: `i/o timeout` during Terraform apply — consistent with transient AWS API throttling.
S3 Log Evidence: All pods healthy, no CrashLoopBackOff, no persistent errors. RC logs show clean state after provision timeout.
Suspect Commits: None — no commits between last passing run (Jun 29, `f4e5d6c`) and current run touch `terraform/` or `scripts/buildspec/`.
Proposed fix: add retry with backoff to `scripts/buildspec/provision-infra-rc.sh` Terraform apply step.

Most recent failure: <url|Build #5678> (Jun 30)

This appears to be a flake — proposed fix: add retry with backoff to Terraform apply in provision-infra-rc.sh.
Should I raise a PR for this? Reply in this thread to confirm.
```

**Example — unclear (request manual investigation):**

```text
:red_circle: *integration -- 8/10 (80%)*

⚠️ *Unclear* — E2E test `TestClusterScaling` failed with unexpected 500 response from platform-api.
Evidence: Prow ✅ | S3 Logs ✅ | Git History ✅ | Trend ✅
Checked: Prow build log (500 error, no stack trace), RC S3 logs (platform-api pod healthy, no errors in application logs, no restarts), MC S3 logs (all pods healthy).
S3 Log Evidence: Broad namespace scan clean — no CrashLoopBackOff, no OOMKilled, no persistent errors across any namespace. platform-api logs show normal request patterns up to failure timestamp.
Suspect Commits: `b2c3d4e` — `refactor(api): restructure scaling handler` — touches `rosa-hyperfleet-api` scaling path, but change appears cosmetic (rename only).
Why Unclear: Evidence is contradictory — S3 logs show fully healthy cluster state, yet platform-api returned 500. Suspect commit exists but change is cosmetic. First occurrence with no matching pattern. Could be a transient race condition not captured in logs.

Most recent failure: <url|Build #9012> (Jun 30)

⚠️ Unable to determine root cause with confidence. Likely cause: race condition in platform-api scaling handler.
This needs manual investigation. Please share findings in this thread — if root cause is identified, I can raise a PR to update the CI troubleshooter to recognize this pattern in future runs.
```

## Constraints

- Keep the top-level summary under 2000 characters. All detailed analysis goes in threaded replies.
- If more than half the jobs return no data, warn about possible Prow/GCS issues at the top.
