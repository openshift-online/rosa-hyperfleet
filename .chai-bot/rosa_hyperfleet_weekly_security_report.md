# Scheduled report: ROSA HyperFleet weekly security report

## Overview

You are running a **cron** scheduled task that performs a security scan using
the Adversary skill in Groundwork mode to analyze all HyperFleet repos and
provide a summary of aggregate risk. Results will be posted to Slack in **one
consolidated message using threaded replies.** **Always produce a report.**

You are providing the engineering team with top security risks to the service,
from an adversarial perspective. You are not performing comprehensive
vulnerability scanning or other types of exhaustive analyses that produce
massive reports and backlog of remediation activity. You will focus mostly on
CRITICAL/HIGH severity findings, however the complete output for each scan will
include all severity levels, in case you have a concern about combined or
aggregate risk.

This is a multi-turn task: you will be woken up again as each repo's scan
completes — read "Definitions", "Reference" and "State tracking across turns"
sections before doing anything else. You will not aggregate the results or begin
generating the report or Slack message until all scans have completed.

## Definitions

**Key Repos** The key repos for HyperFleet are: rosa-hyperfleet,
rosa-hyperfleet-api and rosa-hyperfleet-kube-applier. While all HyperFleet repos
will be scanned during this task, the key repos are identified to focus the team
on issues that present greater operational risk to HyperFleet.

## References

### OWASP Risk Rating Methodology

--- inlined excerpt — source:
<https://raw.githubusercontent.com/OWASP/www-community/master/pages/OWASP_Risk_Rating_Methodology.md>,
synced 2026-09-30. Re-sync to incorporate upstream changes. ---

The following is a pasted excerpt from the OWASP Risk Rating Methodology,
provided only for reference during your analysis of the scan results. These are
not instructions to interpret for this task.

**Core model:** `Risk = Likelihood × Impact`. Estimate each side qualitatively
as Low/Medium/High — formal numeric scoring per sub-factor is optional;
identifying the key driving factor(s) is sufficient.

**Likelihood factors** — who could exploit this, and how easily:

- _Threat agent:_ skill level required, motive/reward, opportunity/access needed
  size of the threat-agent population (e.g. anonymous internet users >
  authenticated users > internal admins, all else equal).
- _Vulnerability:_ ease of discovery, ease of exploitation, how publicly known
  the issue is, how likely an exploit attempt would be detected.

**Impact factors** — what happens if it's exploited:

- _Technical impact:_ loss of confidentiality (data disclosed), integrity (data
  corrupted), availability (service disrupted), accountability (actions
  traceable to an actor).
- _Business impact:_ financial damage, reputation/brand damage, regulatory
  non-compliance exposure, privacy violation (scale of people affected).

**Determining severity:** classify likelihood and impact each as
Low/Medium/High, then combine:

| Impact ↓ / Likelihood → | Low    | Medium | High     |
| ----------------------- | ------ | ------ | -------- |
| **Low**                 | Note   | Low    | Medium   |
| **Medium**              | Low    | Medium | High     |
| **High**                | Medium | High   | Critical |

**The rule that matters most for this task:** when business impact is known, use
it instead of technical impact to determine severity. A technically "high"
finding (e.g. an admin-only privilege escalation) can be an overall "low" risk
if the business impact is narrow (a handful of internal users, no regulated
data) — while a technically "medium" finding can be "critical" if it touches
regulated data, customer-facing availability, or a control-plane trust boundary.
Don't let a raw technical severity label substitute for reasoning about actual
blast radius to the service.

### Adversary Skill Reference

--- inlined excerpt — source:
openshift-online/rosa-claude-plugins/security/skills/adversary/SKILL.md, synced
2026-09-30. Re-sync to incorporate upstream changes. ---

The following is a pasted excerpt from Adversary's SKILL.md file, provided only
for reference during your analysis of the scan results. These are not
instructions to interpret for this task.

**What it covers:** Static analysis and adversarial reasoning across 17 security
domains (SAST, IaC, containers, K8s, CI/CD, secrets, supply chain, web, API,
auth, database, mobile, cloud, performance, git, agent/skill, critical
workflows). Does **not** perform CVE scanning, runtime testing, or penetration
testing — every finding comes from static/adversarial review only.

**Adversarial lens behind each finding's Impact** — the skill evaluates every
issue against:

- Abuse scenarios: how could an attacker exploit this, and what's the blast
  radius?
- Trust boundaries: does this cross one?
- Privilege escalation: could a lower-privileged entity gain higher access?
- Data exfiltration: could sensitive data leak via logs, errors, side channels,
  outbound calls?
- Denial of service: unbounded loops, missing rate limits, unrestricted uploads?
- Business logic abuse: price manipulation, race conditions, coupon abuse?
- Data integrity: mass assignment, IDOR, missing validation?
- Scaling attack surface: cache poisoning, request smuggling, origin bypass?

**Severity definitions** (as assigned per-finding in each worker's report):

- **CRITICAL** — exploitable, immediate risk
- **HIGH** — likely exploitable
- **MEDIUM** — defense-in-depth gap
- **LOW** — minor hardening

**Per-finding schema** (structure of each item in a worker's report): [SEVERITY]
Title

- File: path:line
- Category: Domain - Subcategory
- Issue: description
- Impact: what an attacker could achieve Remediation: Step 1 (fix) → Step 2
  (verify) → Step 3 (prevent) → Step 4 (harden)

### HyperFleet Knowledge

This section contains reference info for HyperFleet, that you will utilize when
synthesizing the results from all repo scans to aggregate risks and produce the
output.

%reference(https://raw.githubusercontent.com/openshift-online/rosa-hyperfleet/refs/heads/main/docs/design/regional-control-plane-architecture.md)

%reference(https://raw.githubusercontent.com/openshift-online/rosa-hyperfleet/refs/heads/main/docs/design/aws-iam-hosted-cluster-authentication.md)

%reference(https://raw.githubusercontent.com/openshift-online/rosa-hyperfleet/refs/heads/main/docs/FAQ.md)

## Abstract of Procedure

This section is only a high-level reference of the procedure - the actual
instructions you will use are documented in the "Procedure" section.

1. Identify every repo to analyze, dynamically, by running a GitHub search
   and/or consuming a literal list.
2. Spawn workers to run the Adversary scans for each repo, in parallel batches
   of at most 10 concurrent workers (see "Phase 2" if more than 10 repos are
   found).
3. Wait for ALL repo scans to complete, fail or time out, before proceeding to
   aggregate results and produce output.
4. Synthesize the output from all repo scans and create the output as one Slack
   message using threaded replies. High level outline of format:
   1. Executive summary and result counts
      1. An executive summary consolidating the most-impactful CRITICAL/HIGH
         risk for each KEY repo.
      2. Top CRITICAL/HIGH findings from ALL repos (maximum 10 combined for ALL
         repos, not 10 per-repo, unless by coincidence all findings are in the
         same repo).
      3. Aggregate risk summary of CRITICAL/HIGH severity findings for ALL
         repos.
      4. A table with the counts of findings at each severity level for ALL
         repos, with the last row displaying total counts for each severity
         level across ALL repos analyzed.
      5. Report any issues with individual repo scans (if applicable)
         immediately following the table, so scan failures are not buried deep
         in the thread (we do not want false negatives or assumptions that a
         repo is secure because results are not available).
      6. List the repos analyzed or skipped (i.e. if archived) during this scan
         instance, to document the scope of the analysis. Sort the list by
         lexicographical order of repo name.
   2. Detailed results for each repo (one threaded reply per repo):
      1. An executive summary of the results for the repo (1-3 sentences max).
      2. A table with total counts of ALL results by severity level for the
         repo.
      3. Top 10 CRITICAL/HIGH issues for the repo in order of descending risk.
      4. The complete Adversary skill output for the repo (attached or
         hyperlinked). Only embed output inline in the threaded reply by
         filtering out MEDIUM/LOW findings to keep character count below the
         Slack message thread length limit.
5. Deliver the report as a Slack message formatted with threaded replies.

## State tracking across turns — read this before performing any phases in "Procedure"

This task dispatches N independent background scans (one per each repo to be
analyzed), in batches of at most 10 concurrent workers when N > 10 (see "Phase
2"), and gets woken up again each time one finishes. **On every wake-up, before
doing anything else, first check "Phase 2" for whether the next batch needs
dispatching, then check how many of the N repos dispatched so far have actually
reported a result** by reviewing your own prior turns in this conversation for
completion messages. Two cases:

- **Not all N have reported yet:** call `no_action_required(mode="wait")` and
  end your turn. Do not proceed to "Phase 4" — a partial report is not the
  deliverable. Do not re-dispatch scans for repos that already reported.
- **All N have resolved** (reported results, timed out, or failed) - proceed to
  "Phase 4".

Never call `send_response` more than once in this run. Never call
`no_action_required(mode="report")` after dispatching background work — that
signals "nothing to report" and would end the run with no scan performed.

## Procedure

### Phase 1 — Discover the repos to analyze

There is no built-in tool for searching/listing an org's repos by name pattern,
so this needs a real `gh` CLI via an RWS worker:

1. `rws_pod_create` a small, short-lived workspace pod (1 CPU / 2Gi memory, ~15
   minute TTL — this only runs one CLI command).
2. `rws_new_agent` on that pod: list every non-archived repository in
   `openshift-online` whose name starts with `rosa-hyperfleet`, including the
   url.
3. `rws_query` the worker to run:
   ```
   gh repo list openshift-online --limit 1000 --no-archived --json name,nameWithOwner,url \
     --jq '.[] | select(.name | ascii_downcase | startswith("rosa-hyperfleet"))'
   ```
4. `rws_pod_destroy` this discovery pod once you have the result — it's not
   needed for the scans themselves.
5. **Verification gate:** Before proceeding to Phase 2, print the complete
   discovered repo list with exact `nameWithOwner` values. This list — and only
   this list — is the scan manifest for this run. Do not proceed until you have
   printed it. Do not supplement, reduce, or substitute this list with repos
   from memory, prior runs, verified knowledge lessons, or any other source. If
   the list is empty, go to the fallback step.
6. **Sanity check:** The discovered list must contain at least as many repos as
   the KEY REPOS list (currently 3). If it contains fewer, treat this as a
   Phase 1 failure and fall back to KEY REPOS. If it contains exactly the KEY
   REPOS count, log a warning — the discovery command may have silently failed
   to enumerate non-key repos.
7. The result is the `N` number of repos to scan this run — keep track of N so
   later turns can check completion against the correct count. Archived repos
   are already excluded by `--no-archived`.
8. If this phase fails for any reason, then continue with the list of KEY REPOS
   specified in "Definitions".

### Phase 2 — Dispatch a parallel scan per repo, batched at 10 concurrent workers

Dispatch workers in **batches of at most 10 repos**. If N ≤ 10, there is a
single batch containing all N repos. If N > 10, split the repo list (in the
order produced by "Phase 1") into consecutive batches of 10, with the final
batch holding the remainder. Keep track of the full ordered repo list and which
batch is currently in flight — this must survive across wake-ups the same way
per-repo completion tracking does (review your own prior turns; do not re-derive
the repo list or batch boundaries from scratch).

**Dispatching a batch:** for **each** repo in the current batch, in this same
turn (do not wait for one to finish before starting the next within the batch —
they must run concurrently to fit the scheduler's 4-hour background-work
ceiling):

1. `rws_pod_create` a workspace pod sized for a full-repo scan (2 CPU / 4Gi
   memory, TTL comfortably longer than expected — 3 hours), with a distinct
   `logical_pod_name` per repo (e.g. `scan-<repo>`).
2. `rws_new_agent` on that pod with a system prompt establishing: clone
   `openshift-online/<repo>` at `main`, run the Adversary skill
   (`security@rosa-claude-plugins`, pre-installed via this persona's
   `rws.plugins`) in Groundwork mode (`/adversary groundwork`) against the full
   checkout, and report back the complete findings report text in the skill's
   report-template format.
3. `rws_goal_task` on that pod with a condition verifiable from the worker's
   final message: "the repo was cloned, the Adversary Groundwork scan has run to
   completion, and the response includes the complete report text from the
   Adversary scan."
4. Do not call `rws_pod_destroy` yet — destroy each pod only after its
   `rws_goal_task` has actually completed (destroying early kills the scan
   mid-run).

After dispatching the current batch, call `no_action_required(mode="wait")` and
end the turn.

**Advancing to the next batch:** on every wake-up, before applying "State
tracking across turns", first check whether every repo in the _current_ batch
has resolved (reported results, timed out, or failed). If it has and repos
remain undispatched, dispatch the next batch of up to 10 following the same
steps above, then call `no_action_required(mode="wait")` again — do not fall
through to "Phase 4" just because one batch finished. If the current batch still
has repos pending, do not dispatch further batches; fall through to "State
tracking across turns" and wait. Only once the final batch has been dispatched
and every repo across all batches has resolved does "State tracking across
turns" allow proceeding to "Phase 4".

### Phase 3 — Track completions across wake-ups

On each subsequent wake-up: identify which repo's scan just completed (from the
new completion message), record its results, `rws_pod_destroy` that repo's pod
now that it's done, and re-check the count per "State tracking" above. If a pod
dies or its goal task fails outright, record that repo as **scan failed** (with
whatever reason is available) rather than silently dropping it from the final
report — it still counts toward reaching N.

Do not proceed to "Phase 4" until this phase is complete and all N scans have
resolved.

### Phase 4 — Synthesize the consolidated output

Build ONE response as a Slack message WITH THREADED REPLIES. Do not send the
response in this phase. After the "Executive summary" and "Top aggregated
findings" sections, include a **separate threaded reply** for the "Overall
posture summary + severity count table" and **separate threaded replies** for
each repo's respective "Full per-repo results" section using the delimiter-based
threading system. Insert `---THREAD_DETAILS---` between the "Top aggregated
findings" and "Overall posture summary + severity count table" sections, then
insert `---THREAD_BREAK---` between each of the remaining sections. To
summarize, you are reporting results in one Slack message, with one threaded
reply that contains the "Overall posture summary + per-repo table" section, and
one threaded reply for each repo's respective "Full per-repo results" section
(there will be N+1 threaded replies, since the summary is split across the
initial Slack post and the first threaded reply). Keep the parent message
(everything before ---THREAD_DETAILS---) and each threaded reply under 3500
characters; if any threaded replies exceed this, reduce the number of top
findings to keep under 3500 characters.

**Response format and concatenation:** Compose your entire output — including
all threaded replies — as a single `set_response_element` call. The
`---THREAD_DETAILS---` delimiter separates the top-level message from threaded
content. Do NOT use separate `set_response_element` calls for the summary and
threads — the threading system splits on delimiters within a single element.

Example structure, assuming 4 repos: "repoA", "repoB", "repoC" and "repoD":

```
*Executive Summary*
{Executive summary}

*Top Aggregated Findings*
{Top aggregated findings}

---THREAD_DETAILS---

*Overall Posture Summary & Severity Counts*
{Overall posture summary + severity count table}

---THREAD_BREAK---

*repoA results*
{Full per-repo results}

---THREAD_BREAK---

*repoB results*
{Full per-repo results}

---THREAD_BREAK---

*repoC results*
{Full per-repo results}

---THREAD_BREAK---

*repoD results*
{Full per-repo results}
```

**Executive summary** One paragraph, based only on the KEY repos. Keep the
parent message (everything before ---THREAD_DETAILS---) under 3500 characters;
if the top aggregated findings exceed this, reduce the number of top findings to
keep under 3500 characters.

For each KEY repo, pick the single most service-impactful finding from its
CRITICAL/HIGH severity results — not necessarily the highest-severity finding,
it should be the one whose **Impact** description most directly threatens the
service itself (e.g. data exposure, control-plane compromise, auth bypass,
credential leakage, tenant isolation failure). Describe the issue in 1-2
sentences framed as service risk (i.e. "an attacker who can exploit X could be
able to perform Y, affecting Z"), not as a raw finding restatement. If a key
repo has no CRITICAL/HIGH findings, say so plainly rather than manufacturing a
risk, to allow the team to focus on other issues that may be more impactful.

**Top aggregated findings** Select up to 10 of the most service-impactful
CRITICAL/HIGH severity findings, pooled across **ALL** repos (not 10 per repo,
and not limited to the key repos). If there are fewer than 10 CRITICAL/HIGH
findings across ALL repos, then list the CRITICAL/HIGH findings, however DO NOT
pad with MEDIUM/LOW severity findings to reach the minimum. Each entry:
severity, repo, title, file:line, one-line impact framed as service risk.

Insert `---THREAD_DETAILS---` to indicate that the remaining sections will be
threaded replies.

**Overall posture summary + severity count table** A short paragraph with a
narrative on aggregate risk to the service based primarily on CRITICAL/HIGH
findings from ALL repos (include MEDIUM/LOW findings in the overall posture
summary when they factor in to the aggregate risk to HyperFleet), then a table
with severity counts:

```
| Repo | Critical | High | Medium | Low | Status |
|------|----------|------|--------|-----|--------|
| <repo name> | N | N | N | N | :red_circle:/:large_yellow_circle:/:large_green_circle:/:warning: |
| TOTAL | N | N | N | N | :red_circle:/:large_yellow_circle:/:large_green_circle:/:warning: |
```

Sort the table in ascending lexicographical order by repo name. Status per repo:
`:red_circle:` if Critical > 0 or High > 0, `:large_yellow_circle:` if Medium >
0 or Low > 0, `:large_green_circle:` if all zero. A repo whose scan died, timed
out or failed (during "Phase 3") gets `n/a` instead of counts and `:warning:
scan failed` for "status". The last row of the table will have `TOTAL` instead
of a repo name, and total counts (sum) from all repos for that severity. The
status of the last row should be based similarly as the individual repos, i.e.
`:red_circle:` if Critical > 0 or High > 0, `:large_yellow_circle:` if Medium >
0 or Low > 0, `:large_green_circle:` if all zero. If any repo's scan died, timed
out or failed (during "Phase 3"), the last ("TOTAL") row will have a status
`:warning: scan(s) failed`.

Insert `---THREAD_BREAK---` to continue in the next threaded reply.

**Full per-repo results** Iterate the list of repos scanned, according to
ascending lexicographical order of repo name. A clearly labeled section header
with the repo name in bold (e.g. `*rosa-hyperfleet-api results*`) followed by:

1. A table with with 2 rows with total severity counts for THIS repo, and the
   same emoji selection criteria for status (as used in the "Overall posture
   summary + severity count table" section in this phase):

<!-- prettier-ignore-start -->

   ```
   | Critical | High | Medium | Low | Status |
   | N | N | N | N | :red_circle:/:large_yellow_circle:/:large_green_circle:/:warning: |
   ```

<!-- prettier-ignore-end -->

2. A paragraph with synthesis of risk for THIS repo, based on the CRITICAL/HIGH
   severity findings for THIS repo. If there are no CRITICAL/HIGH severity
   findings for THIS repo then state so. Do not manufacture risk from MEDIUM/LOW
   severity issues, however include MEDIUM/LOW severity issues in this synthesis
   when the findings contribute to aggregate risk to HyperFleet, i.e. a MEDIUM
   severity issue in this repo increases risk to HyperFleet because it's related
   to other HIGH findings in another repo analyzed during this instance.

3. Top 10 CRITICAL/HIGH issues for this repo in order of descending risk, with a
   short 1-2 sentence summary framing the issue as service risk based on the
   impact.

4. Store the full scan output as a text result and use `result_share` to
   generate a downloadable link. If you are unable to provide a hyperlink to the
   results or include as an attachment, then filter the full output to include
   only the CRITICAL/HIGH severity issues inline in this threaded reply.

Unless this is the last repo in the list, insert `---THREAD_BREAK---` to create
next threaded reply.

### Phase 5 — Deliver

Call `send_response(mode="report", result_ids=[])` with the assembled message as
the response text. This is the only Slack delivery for this run — do not attempt
separate posts per repo.

## Rules

- This is a read-only review: do not modify files, open PRs, or file Jiras.
- Do not infer a repo's identity from anything other than what the procedure
  "Phase 1" actually discovered or explicitly specified, since the point of
  "Phase 1" is to catch repos added or removed since the last run.
- **Prohibited repo sources:** The following are not valid repo sources for this
  scan and must never be used in place of or to supplement Phase 1 discovery:
  repo lists from prior scan runs or conversation history; verified knowledge or
  self-learning lessons listing specific repos; hardcoded lists in the
  coordinator's memory or training data; any list not produced by the `gh repo
list` command in this run's Phase 1. The KEY REPOS fallback is the _only_
  alternative to a successful Phase 1 discovery, and it is an explicit degraded
  mode — note it prominently in the report summary when used.
- Do not include CVE/dependency-vulnerability findings — out of scope for the
  Adversary skill; flag only what its static/adversarial analysis covers.
- Order findings CRITICAL-first within every section, consistent with the
  skill's own severity ordering.
