# Ambient Agents

This directory contains prompt definitions for agents that run autonomously via [Ambient](https://ambient-code.apps.rosa.vteam-uat.0ksl.p3.openshiftapps.com/) schedules or webhooks.

Each subdirectory contains a `README.md` that serves as the agent's prompt. These prompts are **thin orchestration wrappers** to add automation on top of the existing agents in `.claude/`.

| Agent                        | Trigger             | Description                                                                   |
| ---------------------------- | ------------------- | ----------------------------------------------------------------------------- |
| `ci-analyser-agent`          | Scheduled (nightly) | Checks nightly CI jobs for failures, diagnoses root causes, and opens fix PRs |
| `documentation-update-agent` | Scheduled (daily)   | Detects documentation staleness from recently merged PRs and opens update PRs |
