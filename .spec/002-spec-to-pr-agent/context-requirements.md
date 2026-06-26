# Context: Requirements — Spec-to-PR Agent

## Feature Summary

An agentic workflow that takes a feature specification (from a JIRA ticket or design doc) and autonomously implements it end-to-end — writing code and tests, deploying to an ephemeral environment, running e2e tests, debugging failures, and ultimately producing a PR for human review. Includes a circuit breaker to escalate to a human after repeated failures, and persistent memory keyed to JIRA IDs to accumulate context across retry attempts. Also includes a new standalone skill for managing ephemeral environments.

## Codebase Research Findings

- **Existing agents**: adversary, architect, ci-troubleshooter, code-reviewer, documentation-updater, scope-creep-craig, tech-spec-beck
- **Ephemeral env targets**: `ephemeral-{provision,teardown,resync,swap-branch,list,shell,bastion-rc,bastion-mc,port-forward-*,e2e,collect-logs}`
- **E2E testing**: Tests live in `rosa-hyperfleet-api` repo, run via `ci/e2e-tests.sh`, use `make ephemeral-e2e ID=<env-id>`
- **Component repos**: platform-api, maestro-agent, maestro-server, hyperfleet-adapter, hyperfleet-api, hyperfleet-sentinel
- **CLI proxy**: Credential-isolating sidecar for `gh` CLI with deny list for destructive commands
- **Config rendering**: `uv run scripts/render.py` for region configs

## Discovery Questions & Answers

### Q1: Should the agent operate as a single Claude Code session that runs the full implement → deploy → test → debug → retry loop?

**Default if unknown:** Yes
**Answer:** No. The agent will be orchestrated through a **Claude SDK (Python)** application, not a single Claude CLI session. This allows deterministic choices between phases. Within the development phase, we may use agent teams or run additional Claude SDK sessions with predefined personas. The personas branch (psav/persona) contains persona definitions that could be used. The format of existing personas may need modification.

### Q2: Should the agent work across multiple repos?

**Default if unknown:** Yes, cross-repo
**Answer:** Yes. The agent must work across multiple repos (e.g., hypershift, CLI, platform-api). It will use the `resync` feature of ephemeral environments to inject changes from other repos. The agent will run **inside a Podman container** with:

- Access to a workspace for checking out multiple repos
- GitHub user credentials for creating PRs
- Need to consider building and pushing images to Quay (specific detail, eventually make generic)

### Q3: Should ephemeral environment management be a standalone reusable skill?

**Default if unknown:** Yes, standalone
**Answer:** Yes, standalone skill (Recommended).

### Q4: Should the circuit breaker use a simple retry counter, or smarter heuristics?

**Default if unknown:** Simple counter
**Answer:** Both — simple counter as the hard limit, plus heuristics for early bail-out on obvious loops (e.g., same error repeated, no progress between attempts).

## Key Architectural Decisions from Discovery

1. **Orchestration**: Claude SDK (Python) application, not Claude CLI
2. **Execution environment**: Podman container with multi-repo workspace
3. **Session model**: Multi-session with deterministic orchestration between phases
4. **Persona system**: May leverage predefined personas for specialized tasks within development phase
5. **Ephemeral skill**: Standalone, reusable outside the spec-to-pr flow
6. **Circuit breaker**: Dual-mode (counter + heuristics)

## Context Gathering Results

### Persona System (from psav/persona branch)

- 9 personas: api-designer, architect, dba, developer, orchestrator, platform-engineer, qa-engineer, security-engineer, tech-writer
- Each has: Responsibilities, How to Approach, Output, Memory sections
- Orchestrator coordinates specialists — does NOT write code or implement
- Developers self-validate before signaling ready
- Memory writes are immediate and directional; human corrections have highest weight

### Claude Agent SDK (Python) — April 2026

- Production-ready SDK (`pip install claude-agent-sdk`)
- Same agent loop and tools as Claude Code, exposed as a library
- Supports subagents with parallelization and isolated context windows
- Built-in tools: file read, command execution, codebase search
- Runs in your infrastructure (laptop, VPS, K8s, Podman)
- Suitable for building orchestrator with persona-based sessions

### Ephemeral Environment Script (`scripts/dev/ephemeral-env.sh`)

- Commands: provision, teardown, resync, swap-branch, shell, bastion, port-forward, e2e, collect-logs, list
- State tracking: `.ephemeral-envs` file with KEY=VALUE pairs (ID, REPO, BRANCH, STATE, REGION, API_URL, CI_BRANCH, CREATED)
- Credentials: Fetched from Vault via OIDC, never persisted to disk
- Container-based execution with AWS credentials and API URL injection

## Expert Questions & Answers

### Q5: Should the Python orchestrator use the existing persona markdown format directly, or should we define a new structured format (e.g., JSON/YAML) that maps personas to Claude SDK agent configurations?

**Default if unknown:** Yes, use existing format with an adapter layer
**Answer:** New structured format (JSON/YAML). Personas will be defined in a machine-first format with explicit mapping to Claude SDK parameters.

### Q6: Should the JIRA-keyed memory (for circuit breaker context across attempts) be stored as files in the workspace, or in an external store (e.g., a database or JIRA comments)?

**Default if unknown:** Yes, files in workspace
**Answer:** Initially files in workspace. Storage for debug sessions will be decided later — most likely a database of some kind.

### Q7: Should the orchestrator have a "dry run" mode that plans the implementation but stops before deploying/testing, allowing human review of the plan?

**Default if unknown:** Yes
**Answer:** Yes, dry run mode (Recommended).

### Q8: For the standalone ephemeral skill, should it support managing multiple concurrent environments (e.g., for parallel feature development), or one at a time?

**Default if unknown:** Yes, multiple concurrent
**Answer:** Yes, multiple concurrent (Recommended).
