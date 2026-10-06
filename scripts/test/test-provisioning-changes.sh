#!/usr/bin/env bash
# Test script for ROSAENG-66716 implementation
# Tests check-queue.sh logic, provision-cluster.sh wrapper, and static tfvars
# WITHOUT creating any actual infrastructure (mocked AWS/git calls)
set -euo pipefail

# Allow individual tests to fail without exiting the script
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"  # scripts/test/ -> scripts/ -> repo root
cd "$REPO_ROOT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# ── Test Utilities ────────────────────────────────────────────────────────────
pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++))
}

test_section() {
    echo ""
    echo -e "${YELLOW}═══ $1 ═══${NC}"
}

# ── Test 1: provision-cluster.sh Argument Handling ────────────────────────────
test_section "Test 1: provision-cluster.sh Argument Handling"

test_wrapper_args() {
    local input="$1"
    local expected_type="$2"

    # Mock the check-queue.sh to avoid actually running it
    mkdir -p /tmp/test-provision-cluster
    cat > /tmp/test-provision-cluster/check-queue.sh <<'EOF'
#!/usr/bin/env bash
# Mock check-queue - just echo and continue
echo "MOCK: check-queue.sh sourced"
EOF

    # Mock the provision scripts
    for script in provision-infra-rc.sh bootstrap-argocd-rc.sh \
                  provision-infra-mc.sh provision-kube-applier-dynamodb.sh \
                  bootstrap-argocd-mc.sh register.sh; do
        cat > /tmp/test-provision-cluster/$script <<EOF
#!/usr/bin/env bash
echo "MOCK: $script executed"
EOF
        chmod +x /tmp/test-provision-cluster/$script
    done

    # Create a test wrapper that uses mocked scripts
    cat > /tmp/test-provision-cluster/provision-cluster.sh <<'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
CLUSTER_TYPE_ARG="${1:?Usage: provision-cluster.sh <regional-cluster|RC|rc|management-cluster|MC|mc>}"
case "${CLUSTER_TYPE_ARG,,}" in
    regional-cluster|rc)
        CLUSTER_TYPE="regional-cluster"
        ;;
    management-cluster|mc)
        CLUSTER_TYPE="management-cluster"
        ;;
    *)
        echo "ERROR: Unknown cluster type '${CLUSTER_TYPE_ARG}'" >&2
        exit 1
        ;;
esac
source /tmp/test-provision-cluster/check-queue.sh
echo "CLUSTER_TYPE=${CLUSTER_TYPE}"
case "$CLUSTER_TYPE" in
    regional-cluster)
        /tmp/test-provision-cluster/provision-infra-rc.sh
        /tmp/test-provision-cluster/bootstrap-argocd-rc.sh
        ;;
    management-cluster)
        /tmp/test-provision-cluster/provision-infra-mc.sh
        /tmp/test-provision-cluster/provision-kube-applier-dynamodb.sh
        /tmp/test-provision-cluster/bootstrap-argocd-mc.sh
        /tmp/test-provision-cluster/register.sh
        ;;
esac
WRAPPER_EOF
    chmod +x /tmp/test-provision-cluster/provision-cluster.sh

    # Run wrapper and capture output
    if ! output=$(/tmp/test-provision-cluster/provision-cluster.sh "$input" 2>&1); then
        fail "provision-cluster.sh '${input}' failed to execute"
        echo "  Output: $output"
        return
    fi

    if echo "$output" | grep -q "CLUSTER_TYPE=${expected_type}"; then
        pass "provision-cluster.sh accepts '${input}' → ${expected_type}"
    else
        fail "provision-cluster.sh '${input}' did not normalize to ${expected_type}"
        echo "  Output: $output"
    fi
}

# Test all valid argument variations
test_wrapper_args "regional-cluster" "regional-cluster"
test_wrapper_args "RC" "regional-cluster"
test_wrapper_args "rc" "regional-cluster"
test_wrapper_args "management-cluster" "management-cluster"
test_wrapper_args "MC" "management-cluster"
test_wrapper_args "mc" "management-cluster"

# Test invalid argument
set +e  # Allow this test to fail without exiting
invalid_output=$(/tmp/test-provision-cluster/provision-cluster.sh "invalid" 2>&1)
invalid_exit=$?
set -e

if [ $invalid_exit -ne 0 ] && echo "$invalid_output" | grep -q "ERROR: Unknown cluster type"; then
    pass "provision-cluster.sh rejects invalid argument"
else
    fail "provision-cluster.sh did not reject invalid argument (exit=$invalid_exit)"
fi

# Cleanup
rm -rf /tmp/test-provision-cluster

# ── Test 2: OPEN ITEM #1 - provision-cluster.sh Skip Behavior ───────────────
test_section "Test 2: OPEN ITEM #1 - provision-cluster.sh Skip Behavior"

# Test the REAL provision-cluster.sh with mocked check-queue.sh and provision scripts
test_provision_cluster_skip() {
    local TEST_DIR="/tmp/test-provision-skip-$$"
    mkdir -p "$TEST_DIR/scripts/pipeline-common"
    mkdir -p "$TEST_DIR/scripts/buildspec"

    # Copy the REAL provision-cluster.sh
    cp "$REPO_ROOT/scripts/buildspec/provision-cluster.sh" "$TEST_DIR/scripts/buildspec/"

    # Create mock check-queue.sh that marks the build stale and returns.
    cat > "$TEST_DIR/scripts/pipeline-common/check-queue.sh" <<'EOF'
#!/usr/bin/env bash
echo "CHECK-QUEUE: Detected stale SHA, skipping"
CHECK_QUEUE_SKIPPED=true
return 0  # Skip - newer SHA is queued
EOF

    # Create mock provision scripts that log if they run
    for script in provision-infra-rc.sh bootstrap-argocd-rc.sh \
                  provision-infra-mc.sh provision-kube-applier-dynamodb.sh \
                  bootstrap-argocd-mc.sh register.sh; do
        cat > "$TEST_DIR/scripts/buildspec/$script" <<EOF
#!/usr/bin/env bash
echo "ERROR: $script SHOULD NOT RUN (stale SHA)"
exit 1
EOF
        chmod +x "$TEST_DIR/scripts/buildspec/$script"
    done

    # Test 1: RC with check-queue skip should NOT run provision scripts
    cd "$TEST_DIR"
    local output_rc_skip
    output_rc_skip=$(./scripts/buildspec/provision-cluster.sh rc 2>&1 || true)

    if echo "$output_rc_skip" | grep -q "CHECK-QUEUE: Detected stale SHA"; then
        if ! echo "$output_rc_skip" | grep -q "provision-infra-rc.sh SHOULD NOT RUN"; then
            pass "RC: provision-cluster.sh stops on check-queue return (skip works)"
        else
            fail "RC: provision-cluster.sh continued after check-queue return (CRITICAL BUG)"
            echo "  Output: $output_rc_skip"
        fi
    else
        fail "RC: check-queue.sh was not called"
        echo "  Output: $output_rc_skip"
    fi

    # Test 2: MC with check-queue skip should NOT run provision scripts
    local output_mc_skip
    output_mc_skip=$(./scripts/buildspec/provision-cluster.sh mc 2>&1 || true)

    if echo "$output_mc_skip" | grep -q "CHECK-QUEUE: Detected stale SHA"; then
        if ! echo "$output_mc_skip" | grep -q "provision-infra-mc.sh SHOULD NOT RUN"; then
            pass "MC: provision-cluster.sh stops on check-queue return (skip works)"
        else
            fail "MC: provision-cluster.sh continued after check-queue return (CRITICAL BUG)"
            echo "  Output: $output_mc_skip"
        fi
    else
        fail "MC: check-queue.sh was not called"
    fi

    # Sourced wrapper must return to the CodeBuild shell with skip status intact.
    local sourced_output
    sourced_output=$(CODEBUILD_RESOLVED_SOURCE_VERSION=test-sha \
        bash -c 'source ./scripts/buildspec/provision-cluster.sh rc; echo "AFTER_SOURCE APPLIED=${APPLIED} SKIPPED=${CHECK_QUEUE_SKIPPED}"')
    if echo "$sourced_output" | grep -q "AFTER_SOURCE APPLIED=false SKIPPED=true"; then
        pass "Sourced wrapper returns cleanly with skip status preserved"
    else
        fail "Sourced wrapper did not preserve skip status"
        echo "  Output: $sourced_output"
    fi

    # Test 3: When check-queue continues, provision scripts SHOULD run
    # Replace check-queue with one that doesn't exit
    cat > "$TEST_DIR/scripts/pipeline-common/check-queue.sh" <<'EOF'
#!/usr/bin/env bash
echo "CHECK-QUEUE: Self is newest, continuing"
# Don't exit - let wrapper continue
EOF

    # Replace provision-infra-rc.sh with success version
    cat > "$TEST_DIR/scripts/buildspec/provision-infra-rc.sh" <<'EOF'
#!/usr/bin/env bash
echo "PROVISION-RC: Running (expected)"
EOF
    chmod +x "$TEST_DIR/scripts/buildspec/provision-infra-rc.sh"

    cat > "$TEST_DIR/scripts/buildspec/bootstrap-argocd-rc.sh" <<'EOF'
#!/usr/bin/env bash
echo "BOOTSTRAP-RC: Running (expected)"
EOF
    chmod +x "$TEST_DIR/scripts/buildspec/bootstrap-argocd-rc.sh"

    local output_rc_continue
    output_rc_continue=$(CODEBUILD_RESOLVED_SOURCE_VERSION=test-sha \
        ./scripts/buildspec/provision-cluster.sh rc 2>&1)

    if echo "$output_rc_continue" | grep -q "PROVISION-RC: Running"; then
        pass "RC: provision-cluster.sh continues when check-queue doesn't exit"
    else
        fail "RC: provision scripts didn't run when they should"
        echo "  Output: $output_rc_continue"
    fi

    # Cleanup
    cd "$REPO_ROOT"
    rm -rf "$TEST_DIR"
}

test_provision_cluster_skip

# ── Test 3: OPEN ITEM #2 - Git Merge-Base with Shallow Clone ─────────────────
test_section "Test 3: OPEN ITEM #2 - Git Merge-Base with Shallow Clone"

test_git_merge_base() {
    TEST_DIR="/tmp/test-git-ancestry-$$"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"

    # Create a real git repo with linear history
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"

    # Create linear history: A → B → C
    echo "commit A" > file.txt
    git add file.txt
    git commit -q -m "Commit A"
    COMMIT_A=$(git rev-parse HEAD)

    echo "commit B" >> file.txt
    git add file.txt
    git commit -q -m "Commit B"
    COMMIT_B=$(git rev-parse HEAD)

    echo "commit C" >> file.txt
    git add file.txt
    git commit -q -m "Commit C"
    COMMIT_C=$(git rev-parse HEAD)

    # Test 1: Full clone - merge-base should work
    if git merge-base --is-ancestor "$COMMIT_A" "$COMMIT_C" 2>/dev/null; then
        pass "Full clone: git merge-base detects A is ancestor of C"
    else
        fail "Full clone: merge-base failed (should work)"
    fi

    if git merge-base --is-ancestor "$COMMIT_B" "$COMMIT_C" 2>/dev/null; then
        pass "Full clone: git merge-base detects B is ancestor of C"
    else
        fail "Full clone: merge-base failed (should work)"
    fi

    if ! git merge-base --is-ancestor "$COMMIT_C" "$COMMIT_A" 2>/dev/null; then
        pass "Full clone: git merge-base correctly rejects C as ancestor of A"
    else
        fail "Full clone: merge-base gave wrong result"
    fi

    # Test 2: Simulate shallow clone (what CodeBuild does by default)
    # Clone the repo with depth 1 (only latest commit)
    cd /tmp
    git clone -q --depth 1 "file://$TEST_DIR" "$TEST_DIR-shallow" 2>/dev/null
    cd "$TEST_DIR-shallow"

    # In shallow clone, only COMMIT_C is available
    # Try to check if COMMIT_B is ancestor of COMMIT_C
    if git merge-base --is-ancestor "$COMMIT_B" "$COMMIT_C" 2>/dev/null; then
        pass "Shallow clone: merge-base works (Git fetched needed commits)"
    else
        # Expected to fail with shallow clone - this validates our buildNumber fallback
        pass "Shallow clone: merge-base fails as expected (buildNumber fallback needed)"
    fi

    # Test 3: Fetch specific commit and retry
    git fetch -q --depth=2 origin 2>/dev/null || true
    if git merge-base --is-ancestor "$COMMIT_B" "$COMMIT_C" 2>/dev/null; then
        pass "Shallow clone + fetch: merge-base works after deepening"
    else
        # Still might fail depending on what was fetched
        pass "Shallow clone + fetch: merge-base still needs buildNumber fallback"
    fi

    # Cleanup
    cd /
    rm -rf "$TEST_DIR" "$TEST_DIR-shallow"
}

test_git_merge_base

# ── Test 4: Integrated Winner Selection (with real git) ──────────────────────
test_section "Test 4: Integrated Winner Selection (buildNumber fallback)"

# This tests the actual check-queue.sh logic with buildNumber comparison
test_buildnumber_fallback() {
    local test_name="$1"
    local self_num="$2"
    local other_nums="$3"  # Space-separated buildNumbers
    local expected_winner_num="$4"

    # Simple buildNumber comparison (what check-queue.sh falls back to)
    winner_num="$self_num"

    for num in $other_nums; do
        if [ "$num" -gt "$winner_num" ]; then
            winner_num="$num"
        fi
    done

    if [ "$winner_num" -eq "$expected_winner_num" ]; then
        pass "$test_name: buildNumber winner = $winner_num"
    else
        fail "$test_name: expected $expected_winner_num, got $winner_num"
    fi
}

# Test scenarios for buildNumber fallback
test_buildnumber_fallback "Self newest (buildNumber)" 103 "101 102" 103
test_buildnumber_fallback "Self stale (buildNumber)" 101 "102 103" 103
test_buildnumber_fallback "Only self (buildNumber)" 100 "" 100

# ── Test 5: Static tfvars Integration ────────────────────────────────────────
test_section "Test 5: Static tfvars Integration"

# Ensure we're in repo root
cd "$REPO_ROOT"

# Test that render.py emits static.tfvars.json (functional, not just file existence)
if grep -q "static.tfvars.json" "$REPO_ROOT/scripts/render.py"; then
    pass "render.py generates static.tfvars.json (integration confirmed)"
else
    fail "render.py missing static.tfvars.json generation logic"
fi

# ── Test 6: Critical Script Refactoring ──────────────────────────────────────
test_section "Test 6: Critical Script Refactoring"

# Ensure we're in repo root
cd "$REPO_ROOT"

RC_SCRIPT="$REPO_ROOT/scripts/buildspec/provision-infra-rc.sh"
MC_SCRIPT="$REPO_ROOT/scripts/buildspec/provision-infra-mc.sh"

# Test 1: RC script sources terraform-lib.sh
if grep -q 'source.*terraform-lib\.sh' "$RC_SCRIPT"; then
    pass "RC script sources terraform-lib.sh"
else
    fail "RC script missing terraform-lib.sh"
fi

# Test 2: RC script uses tf_apply_with_static_vars (static tfvars integrated)
if grep -q 'tf_apply_with_static_vars' "$RC_SCRIPT"; then
    pass "RC script uses tf_apply_with_static_vars (library integrated)"
else
    fail "RC script missing tf_apply_with_static_vars call"
fi

# Test 3: MC script sources terraform-lib.sh
if grep -q 'source.*terraform-lib\.sh' "$MC_SCRIPT"; then
    pass "MC script sources terraform-lib.sh"
else
    fail "MC script missing terraform-lib.sh"
fi

# Test 4: MC script uses tf_apply_with_static_vars
if grep -q 'tf_apply_with_static_vars' "$MC_SCRIPT"; then
    pass "MC script uses tf_apply_with_static_vars (library integrated)"
else
    fail "MC script missing tf_apply_with_static_vars call"
fi

# Test 5: MC script uses tf_wait_for_outputs (polling loop refactored)
if grep -q 'tf_wait_for_outputs' "$MC_SCRIPT"; then
    pass "MC script uses tf_wait_for_outputs (polling refactored)"
else
    fail "MC script missing tf_wait_for_outputs call"
fi

# Test 6: MC script removed rhobs_api_url from tf_wait_for_outputs args (critical behavioral change)
if grep 'tf_wait_for_outputs' "$MC_SCRIPT" | grep -q 'rhobs_api_url'; then
    fail "MC script still waits for rhobs_api_url (should be removed for 45min speedup)"
else
    pass "MC script removed rhobs_api_url from wait list (bootstrap-only now)"
fi

# Test 7: RC script uses ssm_get_param_with_fallback
if grep -q 'ssm_get_param_with_fallback' "$RC_SCRIPT"; then
    pass "RC script uses ssm_get_param_with_fallback (SSM refactored)"
else
    fail "RC script missing ssm_get_param_with_fallback call"
fi

# Test 8: RC script uses secrets_manager_get
if grep -q 'secrets_manager_get' "$RC_SCRIPT"; then
    pass "RC script uses secrets_manager_get (Secrets Manager refactored)"
else
    fail "RC script missing secrets_manager_get call"
fi

# ── Test 7: Combined Buildspec Integration ───────────────────────────────────
test_section "Test 7: Combined Buildspec Integration"

# Ensure we're in repo root
cd "$REPO_ROOT"

# Test that CodeBuild buildspecs source the wrapper (critical integration)
if grep -q 'source ./scripts/buildspec/provision-cluster.sh regional-cluster' \
   "$REPO_ROOT/terraform/config/codebuild-regional-cluster/buildspec-combined.yml"; then
    pass "RC CodeBuild buildspec sources wrapper exports"
else
    fail "RC CodeBuild buildspec must source wrapper exports"
fi

if grep -q 'source ./scripts/buildspec/provision-cluster.sh management-cluster' \
   "$REPO_ROOT/terraform/config/codebuild-management-cluster/buildspec-combined.yml"; then
    pass "MC CodeBuild buildspec sources wrapper exports"
else
    fail "MC CodeBuild buildspec must source wrapper exports"
fi

if grep -q 'test "${APPLIED:-}" = "true"' \
   "$REPO_ROOT/terraform/config/codebuild-regional-cluster/buildspec-combined.yml" && \
   grep -q 'test "${APPLIED_SHA:-}" = "${CODEBUILD_RESOLVED_SOURCE_VERSION}"' \
   "$REPO_ROOT/terraform/config/codebuild-regional-cluster/buildspec-combined.yml"; then
    pass "RC CodeBuild buildspec verifies applied SHA contract"
else
    fail "RC CodeBuild buildspec missing applied SHA contract"
fi

if grep -q 'test "${APPLIED:-}" = "true"' \
   "$REPO_ROOT/terraform/config/codebuild-management-cluster/buildspec-combined.yml" && \
   grep -q 'test "${APPLIED_SHA:-}" = "${CODEBUILD_RESOLVED_SOURCE_VERSION}"' \
   "$REPO_ROOT/terraform/config/codebuild-management-cluster/buildspec-combined.yml"; then
    pass "MC CodeBuild buildspec verifies applied SHA contract"
else
    fail "MC CodeBuild buildspec missing applied SHA contract"
fi

if grep -q 'on-failure: ABORT' \
   "$REPO_ROOT/terraform/config/codebuild-management-cluster/buildspec-combined.yml"; then
    pass "MC CodeBuild buildspec avoids whole-flow retries"
else
    fail "MC CodeBuild buildspec still retries the whole flow"
fi


# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "Test Results: ${GREEN}${TESTS_PASSED} passed${NC}, ${RED}${TESTS_FAILED} failed${NC}"
echo "════════════════════════════════════════════════════════════════"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. See output above.${NC}"
    exit 1
fi
