# Scripts Test Suite

Automated tests for rosa-hyperfleet scripts and provisioning logic. Tests validate behavior **without creating infrastructure** or requiring AWS credentials.

## Why We Need Tests

Provisioning scripts run in AWS CodeBuild (not locally), control expensive operations (terraform apply, EKS bootstrap), and have complex behavior (git ancestry checks, queue management). Automated tests run in seconds locally and validate all edge cases without AWS access.

## Test Files

### `test-provisioning-changes.sh`

**Story:** ROSAENG-66716 - CodeBuild webhook validation + check-queue.sh + combined buildspecs

**Coverage:** 33 functional tests focused on logic, behavior, and library integration

1. **provision-cluster.sh wrapper** (7 tests) - Argument normalization (RC/rc/regional-cluster, MC/mc/management-cluster)
2. **Skip mechanism** (4 tests) - provision-cluster.sh preserves check-queue.sh skip behavior
3. **Git merge-base** (5 tests) - Ancestry detection with full/shallow clones
4. **BuildNumber fallback** (3 tests) - Winner selection when git ancestry unavailable
5. **Static tfvars integration** (1 test) - render.py generates static.tfvars.json
6. **terraform-lib.sh integration** (8 tests) - Library function usage validation
7. **Combined buildspec integration** (5 tests) - CodeBuild buildspecs source the wrapper and verify the applied SHA contract

**Run time:** ~3-5 seconds  
**Requirements:** bash, git (no AWS credentials, terraform, or infrastructure)

## Running Tests

```bash
# From repo root
./scripts/test/test-provisioning-changes.sh

# Expected output:
# ════════════════════════════════════════════════════════════════
# Test Results: 33 passed, 0 failed
# ════════════════════════════════════════════════════════════════
# ✅ All tests passed!
```

**Exit codes:** 0 = all passed, 1 = one or more failed

**CI Integration:**

```yaml
- name: Test provisioning scripts
  run: ./scripts/test/test-provisioning-changes.sh
```

## Test Patterns

**Mocked Dependencies:** Create temp directories with fake `terraform` and `aws` binaries that return predefined output.

**Real Git Repos:** Create actual git commits to test merge-base logic with full and shallow clones.

**End-to-End:** Test REAL provision-cluster.sh with mocked check-queue.sh and provision scripts to validate skip behavior.

## Adding Tests

```bash
# 1. Create test function
test_my_feature() {
    local TEST_DIR="/tmp/test-$$"
    mkdir -p "$TEST_DIR"

    # Setup, execute, assert
    output=$(command_to_test 2>&1 || true)

    if echo "$output" | grep -q "expected"; then
        pass "Test description"
    else
        fail "Test description"
    fi

    rm -rf "$TEST_DIR"
}

# 2. Add to test sequence
test_section "Test N: My Feature"
test_my_feature

# 3. Update test count in this README
```

## Design Philosophy

**DO test:** Script logic, control flow, critical patterns (source+exit, git merge-base), edge cases, integration between scripts

**DON'T test:** File existence, grep patterns, permissions (CI checks these), infrastructure creation (spike/integration tests), AWS API responses (mock them)

**Test isolation:** Each test uses unique temp directory, cleanup on success/failure, no shared state, read-only access to repo files

## Future Tests

- `test-sdk-provisioner.sh` - CreateProject/UpdateProject/DeleteProject logic (ROSAENG-66717)
- `test-webhook-filters.sh` - FILE_PATH regex translation
- `test-render.sh` - render.py static tfvars generation

## Related Documentation

- [check-queue-skip-logic.md](../../docs/design/check-queue-skip-logic.md) - Skip mechanism design
- [codebuild-optimization.md](../../docs/design/codebuild-optimization.md) - Parent ADR
- [CLAUDE.md](../../CLAUDE.md) - Development workflow
