# Requirements Specification: Spec-to-PR Agent

## Problem Statement

Implementing features for the ROSA Regional Platform requires a developer to manually iterate through a multi-step workflow: understanding the spec, writing code and tests, provisioning ephemeral environments, running e2e tests, debugging failures, and submitting PRs — often across multiple component repositories. This cycle is time-consuming, error-prone, and bottlenecked on human availability for repetitive debugging loops.

## Solution Overview

Build a **Spec-to-PR Agent** — a Python-based orchestrator using the Claude Agent SDK that autonomously drives a feature from specification to pull request. The agent reads a feature spec (JIRA ticket or design doc), implements code and tests across multiple repos, deploys to an ephemeral environment, runs e2e tests, and iterates on failures using a debug loop with persistent memory. A circuit breaker escalates to a human when the agent cannot make progress. The system includes a standalone ephemeral environment management skill and a structured persona system for specialized agent roles.

## Functional Requirements

### FR1: Python Orchestrator

- The orchestrator MUST be a deterministic Python application — all phase transitions, circuit breaker logic, and persona dispatch are in code (not delegated to a Claude agent)
- The orchestrator MUST use the Claude Agent SDK to spawn specialist agent sessions for implementation work
- The orchestrator MUST support a "dry run" mode that plans the implementation and stops before deploying/testing, allowing human review
- The orchestrator MUST accept a work item as input: a JIRA ID, a local spec file (with optional work_id in frontmatter), or inline text
- Every work item MUST have a `work_id` (JIRA ID for JIRA sources, extracted or generated JIRA-style ID for file/inline sources) that serves as the universal key for memory, debug sessions, and state
- The orchestrator MUST support resuming an interrupted or escalated session by work_id, restoring state from persisted storage and continuing from the last completed phase

### FR2: Persona System

- Personas MUST be defined in structured YAML with explicit mapping to Claude SDK `ClaudeAgentOptions` parameters (model, tools, allowed_tools, max_turns, permission_mode, thinking)
- The orchestrator MUST support loading and instantiating personas for specialized tasks
- Personas MUST define: name, description, responsibilities, approach guidance, output format, constraints, memory directives, and sdk_config
- The initial persona set MUST include: developer, qa-engineer, and orchestrator (minimal set); additional personas (architect, security-engineer, etc.) added as needed
- The implementation phase MUST spawn a team of agent sessions using the appropriate personas, coordinated by the deterministic Python orchestrator

### FR3: Implementation Phase

- The agent MUST be able to implement E2E tests for the feature being developed
- The agent MUST be able to implement the feature itself, including:
  - Injecting new versions of components into ArgoCD configurations
  - Implementing new CLM adapters where required
  - Making changes across multiple component repositories (e.g., hypershift, platform-api, CLI)
- The agent MUST refine E2E tests and implementation based on test feedback

### FR4: Multi-Repository Support

- The agent MUST operate across multiple repositories within a shared workspace
- The agent MUST be able to checkout, modify, and commit changes in component repos
- The agent MUST use the ephemeral environment `resync` feature to inject changes from component repos
- The agent MUST be able to create PRs in each affected repository using GitHub credentials
- The agent SHOULD support building and pushing container images to ECR (stretch goal — design for extensibility)

### FR5: Ephemeral Environment Management (Standalone Skill)

- The ephemeral skill MUST be independently invokable outside the spec-to-pr workflow
- The skill MUST support the following operations:
  - **provision**: Create a new ephemeral environment from a branch
  - **teardown**: Destroy an environment and clean up resources
  - **resync**: Re-sync an environment to current branch state
  - **swap-branch**: Switch an environment to a different branch/repo
  - **list**: Display all tracked environments with status
  - **e2e**: Run end-to-end tests against an environment
  - **collect-logs**: Gather Kubernetes logs from clusters
  - **shell**: Open an interactive shell with credentials
  - **bastion**: Connect to RC/MC cluster bastions
  - **port-forward**: Tunnel Kubernetes services (Maestro, ArgoCD, Prometheus, Grafana)
- The skill MUST support managing multiple concurrent environments
- The skill MUST wrap the existing `scripts/dev/ephemeral-env.sh` operations

### FR6: E2E Test Execution

- The agent MUST deploy changes to an ephemeral environment using `make ephemeral-dev` and `make resync`
- The agent MUST run e2e tests against the deployed environment
- The agent MUST capture and parse test results to determine pass/fail

### FR7: Debug Loop

- On e2e failure, the agent MUST enter a debug phase
- The debug phase MUST access: metrics, logs, Kubernetes APIs, and ArgoCD state
- The agent MUST append debug context (findings, hypotheses, attempted fixes) to persistent memory keyed by work_id
- On retry, the agent MUST inject previous attempt context to avoid repeating failed approaches

### FR8: Circuit Breaker

- The circuit breaker MUST enforce a hard retry limit (configurable, default: 3 attempts)
- The circuit breaker MUST implement heuristics for early bail-out:
  - Same error repeated across consecutive attempts
  - No measurable progress between attempts (same test failures, same debug findings)
- When tripped, the circuit breaker MUST notify a human with:
  - Summary of all attempts
  - Debug context and findings
  - Suggested next steps

### FR9: PR Submission

- On successful e2e tests, the agent MUST create a pull request for human review
- The PR MUST include:
  - Summary of changes and the spec that drove them
  - Link to the JIRA ticket
  - Test results from the ephemeral environment
- For multi-repo changes, the agent MUST create coordinated PRs across affected repositories

### FR10: Memory and State Persistence

- Debug session memory MUST initially be stored as files in the workspace, keyed by work_id
- File storage layout: `.spec-to-pr/sessions/{work_id}/` containing session state, per-attempt records, circuit breaker state, and phase context
- The storage mechanism MUST be designed for future migration to a database (adapter pattern)
- Memory MUST persist across orchestrator restarts within the same feature implementation

## Technical Requirements

### TR1: Execution Environment

- The agent MUST run inside a Podman container
- The container MUST have access to a workspace directory for checking out multiple repos
- The container MUST have a limited-access GitHub account for PR creation and repo operations
- AWS credentials MUST be injected into the container at startup (not via Vault OIDC, as browser-based auth is unavailable inside the container)
- The container MUST have access to ECR for pushing container images into ephemeral environments

### TR2: Claude Agent SDK Integration

- The orchestrator MUST use the Claude Agent SDK (Python) for agent sessions via Vertex AI (not Anthropic API directly)
- GCP service account credentials MUST be injected as a JSON file with `GOOGLE_APPLICATION_CREDENTIALS` pointing to it
- Each workflow phase SHOULD run as a separate agent session with appropriate persona
- Context passing between sessions MUST be explicit (via files or structured state)
- The orchestrator MUST handle SDK session failures gracefully

### TR3: Security

- Credentials MUST be injected at container startup and NOT persisted beyond the container lifecycle
- The GitHub account MUST have limited access — scoped to the minimum permissions needed for PR creation and repo operations
- The agent MUST NOT have permissions to merge PRs — only create them for human review
- The agent MAY teardown its own ephemeral environments without confirmation (self-managed lifecycle)
- Force push and other destructive git operations MUST be disabled

### TR4: Observability

- The orchestrator MUST log all phase transitions, decisions, and outcomes
- Debug session context MUST be queryable by work_id
- Circuit breaker events MUST be visible (logged and reported)

## Acceptance Criteria

- AC1: Given a work item (JIRA ID, spec file, or inline), the orchestrator provisions an ephemeral environment, runs e2e tests, and produces a PR on success
- AC2: Given a failing e2e test, the agent enters the debug loop, appends context, and retries with accumulated knowledge
- AC3: Given 3 consecutive failures (or heuristic match), the circuit breaker trips and notifies a human with a summary
- AC4: The ephemeral skill can be invoked standalone to provision, list, resync, and teardown environments
- AC5: Dry run mode produces an implementation plan without deploying or modifying environments
- AC6: Multi-repo changes result in coordinated PRs across all affected repositories
- AC7: Personas load from structured YAML/JSON configs and map correctly to Claude SDK agent parameters

## Constraints

- The existing `scripts/dev/ephemeral-env.sh` script is the source of truth for ephemeral operations — the skill wraps it rather than reimplementing
- E2E tests live in the `rosa-hyperfleet-api` repo, not this repo
- Ephemeral environments require AWS credentials injected at container startup (no Vault OIDC)
- The persona format from the `psav/persona` branch needs to be migrated to structured JSON/YAML
- Image build and push to ECR is a stretch goal — design for it but don't block on it

### Dependencies

- Claude Agent SDK (Python) via Vertex AI — `pip install claude-agent-sdk`
- GCP Vertex AI — Claude model access via service account JSON credentials
- Podman — container runtime for execution environment
- Vault — currently used outside the container to obtain AWS credentials via OIDC (planned for removal); credentials are injected into the container, not fetched via OIDC at runtime
- GitHub API — PR creation and repo management
- AWS — ephemeral environment infrastructure
- Existing Makefile targets — `ephemeral-*` and `int-*` targets
- JIRA API — ticket reading and status updates (optional, can start with local spec files)
