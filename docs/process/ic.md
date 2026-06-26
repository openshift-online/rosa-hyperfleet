# ROSA Regional Platform IC

This document describes the ROSA Regional Platform IC (Interrupt Catcher) process.

## Overview

The IC is the weekly point person for operational interrupts on the ROSA Regional Platform team. The role aims to keep the underlying infrastructure stable and prevent the team from accruing technical debt.

There is no expectation for the IC to be available outside of Business Hours. The IC should review and address their responsibilities at the start of each day.

This role should not prevent the IC from working on their project tasks. The general tasks of the IC should not take more than one hour of your work day. If the workload becomes overwhelming, reach out to the team for help. When the IC asks for help, the entire team should stop what they're doing and help. This is our [Andon Cord](https://www.6sigma.us/six-sigma-in-focus/andon-cord-lean-manufacturing-tps/) ([shorter summary here](https://devlead.io/DevTips/AndonCord)).

The IC is expected to use AI and write automation to reduce the burden on themselves and future ICs. Run `/ic` in Claude Code at the start of each day for an automated briefing covering CI health, the PR queue, and IC queue items. Aspirationally, this role should not exist.

**Make the next IC's shift easier than yours!**

## Responsibilities

The IC is responsible for the following tasks:

- Ensure that the CI jobs are running correctly, in particular:
  - [Nightly Ephemeral](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-hyperfleet-main-nightly-ephemeral)
  - [Nightly Integration](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-hyperfleet-main-nightly-integration)
  - [On-demand E2E](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-hyperfleet-main-on-demand-e2e)
    - Note that only consistent, platform-level failures are the IC's responsibility, as opposed to one-off failures caused by the PRs being tested
- Monitor the PR queue via the [PR Dashboard](https://openshift-online.github.io/rosa-hyperfleet/pr-dashboard):
  - Ensure all review-ready PRs have assigned reviewers
  - Run `/ok-to-test` on bot PRs (dependabot, rosa-hyperfleet-ci, rrp-bot) after verifying they are safe
- Work on items in [ROSAENG-140 - Technical Debt and Continuous Improvement of RRP](https://redhat.atlassian.net/browse/ROSAENG-140).
  - This Epic should only contain urgent tasks to be addressed during the ongoing week.
  - Items on this epic should always be down to zero.

## Rotation

The rotation is managed through PagerDuty:

- [RRP NonProd Schedule](https://redhat.pagerduty.com/schedules/PY55DT7)
- [RRP Non-Production Team](https://redhat.pagerduty.com/teams/P1A9WNI)

If you are unable to take your shift, please trade it with another team member and create the necessary overrides in PagerDuty.
