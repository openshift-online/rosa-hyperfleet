---
description: Log a new Jira issue to ROSAENG with Component (ROSA Regionality Platform) pre-filled.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Goal

Create a new Jira issue in the ROSAENG project with the correct Component pre-filled for the ROSA Regional Platform team.

## Execution Steps

### 1. Parse User Input

Extract the following from `$ARGUMENTS`:

- **Summary** (required): The title/summary of the issue
- **Description** (optional): Detailed description of the work
- **Issue Type** (optional): Defaults to `Story`, but can be `Bug` or `Epic`

If the user provides a simple sentence, use it as the summary. If they provide multiple lines, use the first line as summary and the rest as description.

### 2. Gather Context

**IMPORTANT**: To make this Jira actionable, gather the following context. Ask the user for any missing critical info:

**Required for Stories:**

- What is the goal?
- What are the acceptance criteria? (How do we know it's done)
- Which area of the codebase? (e.g., `terraform/`, `argocd/config/regional-cluster/`, `argocd/config/management-cluster/`)

**Required for Bugs:**

- Steps to reproduce
- Expected vs actual behaviour
- Environment info if relevant

**Helpful for all types:**

- Relevant file paths or components
- Related issues/PRs
- Constraints or out-of-scope items
- Testing requirements

### 3. Build Structured Description

Format the description using this template:

```markdown
## Overview

[One paragraph summary of what needs to be done and why]

## Technical Context

**Area**: [e.g., ArgoCD MC config, Terraform modules, RC services]
**Relevant Paths**:

- `path/to/relevant/file`
- `path/to/another/area/`

## Constraints (if any)

- [What NOT to do]
- [Boundaries to respect]

## Bug Details (for Bugs only)

**Steps to Reproduce**:

1. Step 1
2. Step 2

**Expected**: [what should happen]
**Actual**: [what actually happens]
**Environment**: [cluster/region if relevant]

## Acceptance Criteria (for Stories only)

- [ ] [Criterion 1]
- [ ] [Criterion 2]
- [ ] [Criterion 3]
```

### 4. Find Parent Epic

Stories and Bugs should almost always be linked to an Epic. Before creating:

- Search for open epics in ROSAENG with component "ROSA Regionality Platform"
- Suggest the most relevant epic(s) based on the issue context
- Ask the user which epic to link to
- Issues should not be linked to closed epics

### 5. Confirm Details

Before creating the issue, confirm with the user:

```text
About to create ROSAENG Jira:

Summary: [extracted summary]
Type: [Story/Bug/Epic]
Component: ROSA Regionality Platform
Parent Epic: [ROSAENG-XXXX] (if applicable)

Description Preview:
[Show first 500 chars of formatted description]

Related Links (if any):
- Related Issues: [ROSAENG-XXXX]
- PR: [link if any]

Shall I create this issue? (yes/no/edit)
```

### 6. Create the Jira Issue

Use the JIRA MCP tools to create the issue with:

- **Project**: ROSAENG
- **Summary**: [user provided summary]
- **Issue Type**: [Story/Bug/Epic]
- **Description**: [structured description from template]
- **Component**: ROSA Regionality Platform

Then link it to the parent epic if applicable.

Assign the issue to the current user (look up with atlassianUserInfo).

### 7. Confirm Related Links

If there are any related links we want to add them to the JIRA properly.

All Related Issues should be created as reciprocal links within JIRA to their issue.

PRs should be comma- or newline-separated entries under the "Git Pull Request" field in JIRA.

In the confirmation, we should use natural language for the link types between issues, so if this card relates to ROSAENG-22 and additionally ROSAENG-3 is blocked by this card we should report this as:

```text
Related Links:
- This blocks ROSAENG-3
- This is related to ROSAENG-22
```

Before creating the links, confirm with the user the following template:

```text
About to create JIRA links:

Related Links (if any):
- [list of related links to create]

PR Links (if any):
- [link]

Shall I create these links? (yes/no/edit)
```

### 8. Create the links

Use the JIRA MCP tools to create reciprocal links and PR links after they've been confirmed

### 9. Report Success

After creation, report:

```text
Created: [ISSUE_KEY]
Link: https://redhat.atlassian.net/browse/[ISSUE_KEY]

Summary: [summary]
Type: [type]
Component: ROSA Regionality Platform
Parent Epic: [ROSAENG-XXXX]
Assignee: [name]
```

## Examples

### Quick Story (will prompt for more context)

```text
/jira.log Add remote write configuration for RHOBS
```

The command will then ask for acceptance criteria, relevant paths, and which epic to link to.

### Detailed Story

```text
/jira.log Add ServiceMonitors for all MC services

All services deployed to management clusters need ServiceMonitors so Prometheus can scrape their metrics.

Acceptance:
- ServiceMonitors exist for all deployed MC services
- Metrics are visible in Prometheus
- No scrape errors in Prometheus logs

Area: argocd/config/management-cluster/
Related: ROSAENG-147
```

### Bug Report

```text
/jira.log [Bug] Prometheus not scraping cross-namespace ServiceMonitors

Steps:
1. Deploy a ServiceMonitor in the hypershift namespace
2. Check Prometheus targets
3. ServiceMonitor not listed

Expected: ServiceMonitor appears in Prometheus targets
Actual: ServiceMonitor is not discovered

Fix: Set serviceMonitorNamespaceSelector and serviceMonitorSelectorNilUsesHelmValues in Prometheus config
```

## JIRA Hygiene Reminders

- If you close the last story in an epic, prompt to ask if the epic can be closed as well
- GitHub PRs should be linked in the JIRAs when appropriate
- When we start working on a ticket, mark it as In Progress
- When we're done, mark it as Closed

## Context

$ARGUMENTS
