# Parallel E2E Test Execution

## Overview

The E2E test suite now supports **parallel execution** to reduce wall-clock time by running independent test suites concurrently.

## Architecture

### Two-Phase Execution

**Phase 1: Independent Tests (run in parallel)**
- Platform API tests (`test-e2e-api`)
- ZOA tests (`test-e2e-smoke` or `test-e2e`)

**Phase 2: Dependent Tests (run in parallel, gated by Phase 1 success)**
- HCP creation tests (`test-e2e-cli`)
- ROSA CLI tests (`test-e2e-rosa-cli`)
- Platform Monitoring tests (`test-e2e-platform-monitoring`)

Phase 2 only runs if:
1. Phase 1 completed successfully
2. Customer credentials (`rrp-customer` profile) are available

## Performance Improvement

**Sequential execution (legacy)**: ~14-17 minutes
**Parallel execution**: ~7-10 minutes (~40-50% faster)

## Usage

### Default (Parallel Mode)

```bash
make ephemeral-e2e
```

Parallel mode is **enabled by default**.

### Sequential Mode (Legacy)

```bash
E2E_PARALLEL=false make ephemeral-e2e
```

Use this for debugging or if parallel execution causes issues.

## Logging

### Parallel Mode

Each test suite logs to its own file in `$WORK_DIR`:
- `platform-api.log`
- `zoa.log`
- `hcp-creation.log`
- `rosa-cli.log`
- `monitoring.log`

All logs are displayed at the end of the run for easy review.

### Sequential Mode

Tests write to stdout as before (backward compatible).

## Environment Variables

All existing `E2E_SKIP_*` variables continue to work:

| Variable | Default | Effect |
|----------|---------|--------|
| `E2E_PARALLEL` | `true` | Enable/disable parallel execution |
| `E2E_SKIP_PLATFORM_API` | `false` | Skip Platform API tests |
| `E2E_SKIP_ZOA` | `false` | Skip ZOA tests |
| `E2E_SKIP_HCP` | `false` | Skip HCP creation tests |
| `E2E_SKIP_ROSA_CLI` | `true` | Skip ROSA CLI tests |
| `E2E_SKIP_MONITORING` | `false` | Skip Platform Monitoring tests |

## Example Output

```
=================================================================
Running E2E tests in PARALLEL mode
=================================================================

=== Phase 1: Independent Test Suites ===

▶ Starting platform-api
  Log: /tmp/tmp.abc123/platform-api.log
  PID: 12345

▶ Starting zoa
  Log: /tmp/tmp.abc123/zoa.log
  PID: 12346

=== Waiting for Phase 1 (2 jobs) ===

Waiting for platform-api (PID: 12345)... ✓ (180s)
Waiting for zoa (PID: 12346)... ✓ (120s)

Phase 1 Results:
  Passed: 2
  Failed: 0

=== Phase 2: Dependent Test Suites ===

▶ Starting hcp-creation
  Log: /tmp/tmp.abc123/hcp-creation.log
  PID: 12347

▶ Starting rosa-cli
  Log: /tmp/tmp.abc123/rosa-cli.log
  PID: 12348

▶ Starting monitoring
  Log: /tmp/tmp.abc123/monitoring.log
  PID: 12349

=== Waiting for Phase 2 (3 jobs) ===

Waiting for hcp-creation (PID: 12347)... ✓ (240s)
Waiting for rosa-cli (PID: 12348)... ✓ (180s)
Waiting for monitoring (PID: 12349)... ✓ (120s)

Phase 2 Results:
  Passed: 3
  Failed: 0

=================================================================
Test Suite Logs
=================================================================

--- platform-api ---
[full log output...]

--- zoa ---
[full log output...]

--- hcp-creation ---
[full log output...]

--- rosa-cli ---
[full log output...]

--- monitoring ---
[full log output...]

=================================================================

E2E results: platform=0 hcp=0 monitoring=0 rosa-cli=0 zoa=0
```

## Failure Handling

If any test in Phase 1 fails:
- Phase 1 completes all running tests
- Phase 2 is skipped
- All logs are displayed
- Script exits with code 1

If any test in Phase 2 fails:
- Phase 2 completes all running tests
- All logs are displayed
- Script exits with code 1

## Compatibility

- **Bash 3.2+**: Works on macOS default bash and modern Linux distributions
- **Existing CI**: No changes required to CI pipelines
- **Local development**: Works with `make ephemeral-e2e`
- **Prow jobs**: Automatically uses parallel mode

## Debugging

### View individual test logs during execution

```bash
# In another terminal while tests are running
tail -f /tmp/tmp.*/platform-api.log
tail -f /tmp/tmp.*/zoa.log
```

### Force sequential execution for debugging

```bash
E2E_PARALLEL=false make ephemeral-e2e
```

### Skip specific suites for faster iteration

```bash
E2E_SKIP_MONITORING=true \
E2E_SKIP_ROSA_CLI=true \
make ephemeral-e2e
```

## Implementation Details

The parallel orchestration uses:
- Background jobs with `&` for concurrent execution
- PID tracking for job management
- Separate log files per test suite
- Bash 3.2-compatible job metadata (no associative arrays)
- Clean signal handling (SIGINT, SIGTERM)
- Proper exit code propagation
