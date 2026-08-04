# Implementation Plan: Spec-to-PR Agent

## Technical Approach

Build a Python package (`spec-to-pr/`) containing a deterministic orchestrator that drives a state machine through the spec → implement → deploy → test → debug → PR workflow. The orchestrator uses the Claude Agent SDK to spawn persona-based agent sessions for AI work (implementation, debugging), while keeping all phase transitions, circuit breaker logic, and session coordination in deterministic Python code.

Personas are defined as extended `.claude/agents/` files (standard frontmatter for Claude Code compatibility + extra fields for the orchestrator). The ephemeral environment skill is a separate `.claude/commands/ephemeral.md` command. State is persisted as YAML files keyed by `work_id`.

## Implementation

### Milestone 1: Project Scaffolding & Core Data Models

#### Phase 1: Package Setup

- [ ] Step 1: Create `spec-to-pr/` directory with `pyproject.toml`

```toml
[project]
name = "spec-to-pr"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = [
    "claude-agent-sdk",
    "pyyaml",
]

[project.scripts]
spec-to-pr = "spec_to_pr.cli:main"
```

- [ ] Step 2: Create package structure

```
spec-to-pr/
  pyproject.toml
  src/
    spec_to_pr/
      __init__.py
      cli.py
      models/
        __init__.py
        work_item.py
        session.py
        circuit_breaker.py
        phase_context.py
      orchestrator.py
      state_machine.py
      personas.py
      storage.py
  tests/
    __init__.py
    test_state_machine.py
    test_circuit_breaker.py
    test_personas.py
    test_storage.py
```

- [ ] Step 3: Verify package installs with `uv pip install -e spec-to-pr/`

#### Phase 2: Data Models (TDD)

- [ ] Step 4: Write tests for `WorkItem` model — construction from JIRA ID, file path (with frontmatter work_id), and inline text

```python
def test_work_item_from_jira():
    item = WorkItem.from_jira("ROSAENG-1234")
    assert item.work_id == "ROSAENG-1234"
    assert item.source_type == SourceType.JIRA

def test_work_item_from_file_with_frontmatter():
    item = WorkItem.from_file("spec.md")  # file has work_id: SPEC-0001
    assert item.work_id == "SPEC-0001"

def test_work_item_from_file_without_frontmatter():
    item = WorkItem.from_file("spec.md")  # no frontmatter work_id
    assert item.work_id.startswith("SPEC-")
```

- [ ] Step 5: Implement `WorkItem` dataclass in `models/work_item.py`
- [ ] Step 6: Run tests — expect all passing
- [ ] Step 7: Write tests for `OrchestratorSession`, `RepoState`, `DebugMemoryEntry`, `CircuitBreakerState`, `PhaseContext` models based on the data model spec
- [ ] Step 8: Implement all model dataclasses
- [ ] Step 9: Run tests — expect all passing
- [ ] Step 10: Commit changes

### Milestone 2: State Machine & Circuit Breaker

#### Phase 3: State Machine (TDD)

- [ ] Step 11: Write tests for state transitions — all valid transitions from the state machine spec

```python
def test_spec_ingestion_to_implementation():
    sm = StateMachine(session)
    next_phase = sm.transition(Phase.SPEC_INGESTION, spec_valid=True, dry_run=False)
    assert next_phase == Phase.IMPLEMENTATION

def test_spec_ingestion_to_dry_run():
    sm = StateMachine(session)
    next_phase = sm.transition(Phase.SPEC_INGESTION, spec_valid=True, dry_run=True)
    assert next_phase == Phase.DRY_RUN_REVIEW

def test_e2e_pass_to_pr_submission():
    sm = StateMachine(session)
    next_phase = sm.transition(Phase.E2E_EXECUTION, tests_passed=True)
    assert next_phase == Phase.PR_SUBMISSION

def test_e2e_fail_to_debug():
    sm = StateMachine(session)
    next_phase = sm.transition(Phase.E2E_EXECUTION, tests_passed=False)
    assert next_phase == Phase.DEBUG

def test_invalid_transition_raises():
    sm = StateMachine(session)
    with pytest.raises(InvalidTransitionError):
        sm.transition(Phase.COMPLETE, ...)
```

- [ ] Step 12: Implement `StateMachine` class in `state_machine.py` using match/case
- [ ] Step 13: Run tests — expect all passing

#### Phase 4: Circuit Breaker (TDD)

- [ ] Step 14: Write tests for circuit breaker logic

```python
def test_breaker_trips_on_max_attempts():
    cb = CircuitBreaker(max_attempts=3)
    cb.record_attempt(error_fingerprint="abc", progress_score=0.5)
    cb.record_attempt(error_fingerprint="def", progress_score=0.3)
    cb.record_attempt(error_fingerprint="ghi", progress_score=0.1)
    assert cb.tripped is True
    assert cb.trip_reason == TripReason.MAX_ATTEMPTS_REACHED

def test_breaker_trips_on_repeated_error():
    cb = CircuitBreaker(max_attempts=5)
    cb.record_attempt(error_fingerprint="abc", progress_score=0.5)
    cb.record_attempt(error_fingerprint="abc", progress_score=0.5)
    assert cb.tripped is True
    assert cb.trip_reason == TripReason.REPEATED_ERROR

def test_breaker_trips_on_no_progress():
    cb = CircuitBreaker(max_attempts=5)
    cb.record_attempt(error_fingerprint="abc", progress_score=0.3)
    cb.record_attempt(error_fingerprint="def", progress_score=0.3)
    assert cb.tripped is True
    assert cb.trip_reason == TripReason.NO_PROGRESS

def test_breaker_allows_retry():
    cb = CircuitBreaker(max_attempts=3)
    cb.record_attempt(error_fingerprint="abc", progress_score=0.5)
    assert cb.tripped is False
```

- [ ] Step 15: Implement `CircuitBreaker` class in `models/circuit_breaker.py`
- [ ] Step 16: Run tests — expect all passing
- [ ] Step 17: Commit changes

### Milestone 3: Storage & Persona Loading

#### Phase 5: File Storage

- [ ] Step 18: Write tests for storage adapter — save/load session, debug entries, circuit breaker state

```python
def test_save_and_load_session(tmp_path):
    storage = FileStorage(base_path=tmp_path)
    storage.save_session(session)
    loaded = storage.load_session("ROSAENG-1234")
    assert loaded.work_item.work_id == "ROSAENG-1234"

def test_save_and_load_debug_entry(tmp_path):
    storage = FileStorage(base_path=tmp_path)
    storage.save_debug_entry("ROSAENG-1234", entry)
    entries = storage.load_debug_entries("ROSAENG-1234")
    assert len(entries) == 1
```

- [ ] Step 19: Implement `FileStorage` class in `storage.py` with adapter interface (for future DB migration)
- [ ] Step 20: Run tests — expect all passing

#### Phase 6: Persona Loading

- [ ] Step 21: Write tests for persona parser — reads `.claude/agents/` files, extracts standard + extended frontmatter, parses markdown body

```python
def test_load_persona_from_agent_file():
    persona = PersonaLoader.load("developer")
    assert persona.name == "developer"
    assert persona.sdk_config.model == "claude-sonnet-4-6"
    assert persona.sdk_config.max_turns == 100
    assert "Do not merge PRs" in persona.constraints

def test_persona_to_sdk_options():
    persona = PersonaLoader.load("developer")
    options = persona.to_sdk_options(phase_context=ctx)
    assert options.model == "claude-sonnet-4-6"
    assert "You are developer" in options.system_prompt
```

- [ ] Step 22: Implement `PersonaLoader` and `Persona` classes in `personas.py`
- [ ] Step 23: Run tests — expect all passing
- [ ] Step 24: Commit changes

### Milestone 4: Orchestrator Core Loop

#### Phase 7: Orchestrator Implementation

- [ ] Step 25: Implement `Orchestrator` class in `orchestrator.py` — the main run loop

```python
class Orchestrator:
    def __init__(self, config: Config):
        self.state_machine = StateMachine()
        self.storage = FileStorage(config.storage_path)
        self.persona_loader = PersonaLoader(config.agents_path)

    def run(self, work_item: WorkItem, dry_run: bool = False):
        session = OrchestratorSession(work_item=work_item, dry_run=dry_run)
        self.storage.save_session(session)

        while not session.is_terminal:
            match session.current_phase:
                case Phase.SPEC_INGESTION:
                    self._ingest_spec(session)
                case Phase.IMPLEMENTATION:
                    self._run_implementation_team(session)
                case Phase.DEPLOYMENT:
                    self._deploy(session)
                case Phase.E2E_EXECUTION:
                    self._run_e2e(session)
                case Phase.DEBUG:
                    self._debug(session)
                case Phase.CIRCUIT_BREAKER_CHECK:
                    self._check_circuit_breaker(session)
                case Phase.PR_SUBMISSION:
                    self._submit_prs(session)
                ...
```

- [ ] Step 26: Implement `_ingest_spec()` — parse work item, load spec content
- [ ] Step 27: Implement `_run_implementation_team()` — spawn Claude SDK subagents with developer/qa personas
- [ ] Step 28: Implement `_deploy()` — call `make ephemeral-dev` and `make resync` via subprocess
- [ ] Step 29: Implement `_run_e2e()` — call `make ephemeral-e2e`, parse test output
- [ ] Step 30: Implement `_debug()` — spawn debug agent session, collect findings, save debug memory entry
- [ ] Step 31: Implement `_check_circuit_breaker()` — evaluate breaker state, transition to retry or escalation
- [ ] Step 32: Implement `_submit_prs()` — create PRs via `gh` CLI for each modified repo
- [ ] Step 33: Implement `_escalate()` — format and output human escalation report
- [ ] Step 34: Commit changes

#### Phase 8: CLI Entry Point

- [ ] Step 35: Implement `cli.py` with argparse

```
spec-to-pr run --work-id ROSAENG-1234 --source jira
spec-to-pr run --file spec.md
spec-to-pr run --inline "Add health check endpoint"
spec-to-pr run --file spec.md --dry-run
spec-to-pr status --work-id ROSAENG-1234
spec-to-pr resume --work-id ROSAENG-1234
```

- [ ] Step 36: Run full unit test suite — expect all passing
- [ ] Step 37: Commit changes

### Milestone 5: Persona Agent Files

#### Phase 9: Create Initial Personas

- [ ] Step 38: Create `.claude/agents/developer.md` with standard + extended frontmatter
- [ ] Step 39: Create `.claude/agents/qa-engineer.md` with standard + extended frontmatter
- [ ] Step 40: Verify the existing `.claude/agents/` files are not affected by the new persona files
- [ ] Step 41: Commit changes

### Milestone 6: Ephemeral Environment Skill

#### Phase 10: Claude Code Command

- [ ] Step 41: Create `.claude/commands/ephemeral.md` wrapping Make targets

```markdown
---
description: Manage ephemeral environments (provision, teardown, resync, list, e2e, logs)
---

Parse the user's request from: $ARGUMENTS

## Available Operations

- provision: `make ephemeral-provision ID=<id> BRANCH=<branch>`
- teardown: `make ephemeral-teardown ID=<id>`
- resync: `make ephemeral-resync ID=<id>`
- list: `make ephemeral-list`
- e2e: `make ephemeral-e2e ID=<id>`
- collect-logs: `make ephemeral-collect-logs ID=<id>`
- shell: `make ephemeral-shell ID=<id>`
- swap-branch: `make ephemeral-swap-branch ID=<id> BRANCH=<branch>`
  ...
```

- [ ] Step 43: Test the skill manually with `claude /ephemeral list`
- [ ] Step 44: Commit changes

### Milestone 7: Container & Documentation

#### Phase 11: Containerfile

- [ ] Step 42: Create `spec-to-pr/Containerfile` based on UBI9

```dockerfile
FROM registry.access.redhat.com/ubi9/python-313:latest
USER 0
RUN dnf install -y git make curl && \
    curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo | tee /etc/yum.repos.d/github-cli.repo && \
    dnf install -y gh && \
    dnf clean all
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /workspace
COPY spec-to-pr/ /opt/spec-to-pr/
RUN uv pip install --system /opt/spec-to-pr/
USER 1001
ENTRYPOINT ["spec-to-pr"]
```

- [ ] Step 43: Build and verify container runs: `podman build -t spec-to-pr -f spec-to-pr/Containerfile .`
- [ ] Step 44: Commit changes

#### Phase 12: Project Documentation

- [ ] Step 45: Create `spec-to-pr/README.md` covering usage, architecture, persona configuration, and environment variables
- [ ] Step 46: Commit changes

### Milestone 8: Integration Testing & Validation

#### Phase 13: Integration Tests (Mocked)

- [ ] Step 47: Write integration tests mocking Claude SDK calls — verify full orchestrator loop from spec ingestion to PR submission
- [ ] Step 48: Write integration tests mocking ephemeral env calls — verify deploy and e2e phases
- [ ] Step 49: Write integration test for circuit breaker integration — verify escalation flow
- [ ] Step 50: Write integration test for resume — verify session loads from storage and continues from correct phase
- [ ] Step 51: Run full test suite — expect all passing
- [ ] Step 52: Commit changes

#### Phase 14: Real Environment Validation

- [ ] Step 53: Manual test with a simple spec file — run `spec-to-pr run --file test-spec.md --dry-run` and verify plan output
- [ ] Step 54: Manual test with a real ephemeral environment — run full loop against a trivial change
- [ ] Step 55: Verify circuit breaker trips correctly with a deliberately failing spec
- [ ] Step 56: Verify resume works after circuit breaker escalation
- [ ] Step 57: Verify PR creation across repos

## Summary of Changes in Key Technical Areas

### Components to Create

| Component            | Path                            | Purpose                                                          |
| -------------------- | ------------------------------- | ---------------------------------------------------------------- |
| Orchestrator package | `spec-to-pr/`                   | Python package with CLI, state machine, storage, persona loading |
| Developer persona    | `.claude/agents/developer.md`   | Implementation agent with extended SDK config                    |
| QA Engineer persona  | `.claude/agents/qa-engineer.md` | Testing agent with extended SDK config                           |
| Ephemeral skill      | `.claude/commands/ephemeral.md` | Standalone env management command                                |

### Components to Create (continued)

| Component             | Path                       | Purpose                                         |
| --------------------- | -------------------------- | ----------------------------------------------- |
| Containerfile         | `spec-to-pr/Containerfile` | Container image definition for the orchestrator |
| Project documentation | `spec-to-pr/README.md`     | Usage, architecture, and configuration docs     |

### Database Changes

None — file-based storage initially. Adapter pattern for future DB migration.

### API Changes

CLI interface only:

- `spec-to-pr run` — execute the workflow
- `spec-to-pr status` — check session state
- `spec-to-pr resume` — resume interrupted session

### User Interface Changes

- New `/ephemeral` Claude Code command for interactive env management
- New persona agent files visible in Claude Code agent selection

## Testing Strategy

| Layer                      | Approach                                       | When                              | Runner              |
| -------------------------- | ---------------------------------------------- | --------------------------------- | ------------------- |
| Unit tests                 | TDD for state machine, circuit breaker, models | Before implementation             | `pytest`            |
| Unit tests                 | Test-after for persona loading, storage        | After implementation              | `pytest`            |
| Integration tests (mocked) | Mock SDK + subprocess calls                    | After orchestrator implementation | `pytest` with mocks |
| Validation (real)          | Manual tests against ephemeral env             | After all code complete           | Manual              |

**Expected test output:**

```
tests/test_state_machine.py ............ PASSED
tests/test_circuit_breaker.py ......... PASSED
tests/test_personas.py ...... PASSED
tests/test_storage.py ........ PASSED
tests/test_orchestrator.py .............. PASSED
```

**How to run:**

```bash
cd spec-to-pr && uv run pytest tests/ -v
```

## Deployment Considerations

- The orchestrator runs inside a Podman container defined by `spec-to-pr/Containerfile`
- AWS credentials MUST be injected at container startup as environment variables
- GitHub token MUST be available as `GITHUB_TOKEN` env var
- Claude access via Vertex AI — gcloud credentials MUST be injected (service account key or workload identity)
- The container needs a workspace directory mounted as a volume for multi-repo checkout
- GCP service account credentials MUST be injected as a JSON file (e.g., mounted at `/secrets/gcp-sa.json`) with `GOOGLE_APPLICATION_CREDENTIALS` env var pointing to it
- The Containerfile MUST install: Python >=3.13, uv, git, gh CLI, make, and the spec-to-pr package
