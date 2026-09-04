# Scheduled report: ROSA HyperFleet family Adversary security scan

You are running a **cron** scheduled task that performs a weekly Adversary security scan and posts the results to Slack. **Always produce a report.** **Never** call `no_action_required()`.

This file is shared across all `rosa-hyperfleet*` repos via `%include()` — it does not name a specific repository. The task invoking this file supplies a `Repository:` line as context immediately before the `%include()` line; use that value everywhere this procedure refers to "the target repository." If no such context is present, treat this repository (`openshift-online/rosa-hyperfleet`) as the target. The Slack destination is not something you need to know or specify — deliver your report via `send_response()` as usual and the scheduler posts it to whichever channel this task is configured for.

This does not perform CVE scanning, runtime testing, or penetration testing — it's static/adversarial analysis of the repo, same as the `security:adversary` skill.

## Goal

Run a full-repo Groundwork-mode Adversary scan of the target repository (not a diff-based review — this is a periodic audit, not a PR check) and post a concise severity-ranked summary, with the full findings report available in a threaded reply.

## Procedure

### 1. Provision a workspace and run the real Adversary skill

Do **not** fetch the skill's markdown and interpret it yourself — this persona has the `security` plugin (`openshift-online/rosa-claude-plugins`, `security/` directory) pre-installed on its RWS workers via the `rws.plugins` config, so a worker's Claude Code session has the actual `adversary` skill available natively. Run the scan as a real skill invocation, not a re-implementation:

1. `rws_pod_create` a workspace pod sized for a full-repo scan (e.g. 2 CPU / 4Gi memory), with a TTL comfortably longer than the scan is expected to take (90+ minutes).
2. `rws_new_agent` on that pod with a system prompt establishing the task: clone the target repository at `main`, then run the Adversary skill in Groundwork mode against the full checkout, and return complete findings.
3. `rws_query` the worker to: clone the target repository, `cd` into it, and invoke `/adversary groundwork` (or the equivalent groundwork-mode trigger described by the skill's `when_to_use`). The worker's own Claude Code session executes the skill's full procedure — reading `CLAUDE.md`/`AGENTS.md`, detecting the tech stack, running its discovery scripts, and applying its domain checklists — you don't need to replicate any of that logic here.
4. Ask the worker to return, as its final response: severity counts (CRITICAL/HIGH/MEDIUM/LOW), overall risk level, top priority fix, the top 5 findings, and the full findings report text (all findings + remediation + security posture summary) in the skill's report-template format.
5. `rws_pod_destroy` the pod once you have the result — don't leave it running.

If RWS or the worker's Claude Code session is unavailable for any reason, fall back to fetching `https://raw.githubusercontent.com/openshift-online/rosa-claude-plugins/main/security/skills/adversary/SKILL.md` (and its `references/` files, fetched on demand) and following the procedure yourself against the target repository via your GitHub source tools. Note in the Slack report that this run used the fallback path, since it does not benefit from the skill's bundled scripts.

### 2. Post to Slack

Post one top-level message with:

```
{emoji} *Adversary Scan — {repo} ({DATE})*

*Scan Mode:* Groundwork (full repo)   *Findings:* {CRITICAL}C / {HIGH}H / {MEDIUM}M / {LOW}L

*Overall Risk:* {risk_level}
*Top Priority:* {top_fix}

{IF findings exist}
*Top findings:*
- [{SEVERITY}] {title} — `{file}:{line}`
...(up to 5, most severe first)
{END}

Full report in thread :thread:
```

- `{repo}`: the target repository's short name (e.g. `rosa-hyperfleet-api`), from the `Repository:` context line.
- `{emoji}`: 🔴 if any CRITICAL or HIGH findings, 🟡 if only MEDIUM/LOW, 🟢 if clean.
- If there are zero findings, state "No security issues identified in this scan." and skip the "Top findings" section and thread reply.

### 3. Thread reply (full report)

If there are any findings, post the complete findings report (all findings, full remediation steps, security posture summary) returned by the worker as a **single threaded reply**. Do not split it across the top-level message — keep the channel message scannable.

## Rules

- Always produce a report, even on a clean scan — say so explicitly rather than posting nothing.
- This is a read-only review: do not modify files, open PRs, or file Jiras automatically.
- Do not include CVE/dependency-vulnerability findings — that's out of scope for this skill; flag only what Adversary's static/adversarial analysis covers.
- Keep the top-level Slack message well under 2500 characters; move detail to the thread.
- Order findings CRITICAL-first, consistent with the skill's severity ordering.

## Constraints

- Always produce a report, even if there was nothing to flag.
- Never call `no_action_required()`.
- Do not include the `[Scheduled task: ...]` metadata line in the output.
