#!/usr/bin/env bash
# Check CodeBuild queue and skip stale commits.
# Called from: scripts/buildspec/provision-cluster.sh (MUST be sourced)
#
# ── Summary ───────────────────────────────────────────────────────────────────
# When a build starts, check if a newer git commit is queued. If yes, stop older
# queued builds and exit 0 (skip — newer SHA will apply). Only the newest queued
# commit proceeds to terraform apply.
#
# Savings: 30-90 min per stale commit skipped. Rapid pushes (A→B→C) complete in
# 60min instead of 90min (A applies, B+C skip in <1min each).
#
# ── Full Documentation ────────────────────────────────────────────────────────
# See docs/design/check-queue-skip-logic.md for:
#   - Problem statement and example timeline
#   - Winner selection algorithm (git ancestry + buildNumber fallback)
#   - Source vs. execute distinction (why 'source' is critical)
#   - Safety guarantees and troubleshooting
#
# ── CRITICAL: Must be sourced (not executed) ──────────────────────────────────
# provision-cluster.sh does: source scripts/pipeline-common/check-queue.sh
# When sourced, 'exit 0' kills the wrapper → buildspec sees exit 0 = skip.
# If executed (./check-queue.sh), exit 0 only stops subprocess → provision runs.
#
# OPEN ITEM (spike validation): git merge-base may require full clone depth or
# explicit fetch. Current implementation has buildNumber fallback (works either way).
set -euo pipefail

# ── Self identity ─────────────────────────────────────────────────────────────
SELF_BUILD_ID="${CODEBUILD_BUILD_ID:?CODEBUILD_BUILD_ID not set}"
SELF_SHA="${CODEBUILD_RESOLVED_SOURCE_VERSION:?CODEBUILD_RESOLVED_SOURCE_VERSION not set}"
SELF_BUILD_NUMBER="${CODEBUILD_BUILD_NUMBER:?CODEBUILD_BUILD_NUMBER not set}"

# Extract project name from build ID (format: project-name:uuid)
PROJECT_NAME="${SELF_BUILD_ID%%:*}"

echo "check-queue: self=${SELF_BUILD_ID} sha=${SELF_SHA} buildNumber=${SELF_BUILD_NUMBER}"

# ── List queued builds for this project ──────────────────────────────────────
BUILD_IDS=$(aws codebuild list-builds-for-project \
    --project-name "$PROJECT_NAME" \
    --sort-order ASCENDING \
    --query 'ids' \
    --output text)

if [ -z "$BUILD_IDS" ]; then
    echo "check-queue: no builds found for project ${PROJECT_NAME}"
    # Self is the only build; continue
    exit 0
fi

# ── Get build details ─────────────────────────────────────────────────────────
BUILDS_JSON=$(aws codebuild batch-get-builds \
    --ids $BUILD_IDS \
    --query 'builds[*].[id,buildNumber,buildStatus,currentPhase,resolvedSourceVersion]' \
    --output json)

# ── Collect QUEUED builds (never stop builds past pre_build phase) ───────────
# Why QUEUED only? We never want to stop a build already running terraform apply.
# buildStatus progression: QUEUED → IN_PROGRESS (pre_build → build → post_build) → SUCCEEDED/FAILED
QUEUED_BUILDS=$(echo "$BUILDS_JSON" | jq -r '.[] | select(.[2] == "QUEUED") | @json')

if [ -z "$QUEUED_BUILDS" ]; then
    echo "check-queue: no queued builds; continuing"
    exit 0
fi

echo "check-queue: found $(echo "$QUEUED_BUILDS" | wc -l) queued build(s)"

# ── Determine newest commit among self + queued builds ───────────────────────
# Winner selection:
#   1. git merge-base --is-ancestor for ancestry (with fallback if shallow clone)
#   2. Unrelated SHAs → higher buildNumber wins

declare -A BUILD_MAP  # sha -> "buildId|buildNumber"

# Add self
BUILD_MAP["$SELF_SHA"]="${SELF_BUILD_ID}|${SELF_BUILD_NUMBER}"

# Add queued builds
while IFS= read -r build_json; do
    BUILD_ID=$(echo "$build_json" | jq -r '.[0]')
    BUILD_NUM=$(echo "$build_json" | jq -r '.[1]')
    SHA=$(echo "$build_json" | jq -r '.[4]')

    if [ "$BUILD_ID" == "$SELF_BUILD_ID" ]; then
        continue  # Skip self (already added)
    fi

    BUILD_MAP["$SHA"]="${BUILD_ID}|${BUILD_NUM}"
    echo "check-queue: queued build ${BUILD_ID} buildNumber=${BUILD_NUM} sha=${SHA}"
done <<< "$QUEUED_BUILDS"

# ── Find newest SHA ───────────────────────────────────────────────────────────
# Winner = newest commit among self + queued builds (proceeds to terraform apply)
NEWEST_SHA=""
NEWEST_BUILD_NUM=0

for sha in "${!BUILD_MAP[@]}"; do
    build_num=$(echo "${BUILD_MAP[$sha]}" | cut -d'|' -f2)

    if [ -z "$NEWEST_SHA" ]; then
        NEWEST_SHA="$sha"
        NEWEST_BUILD_NUM="$build_num"
        continue
    fi

    # Try git ancestry comparison (may fail on shallow clone — fallback to buildNumber)
    # OPEN ITEM: spike will validate if we need git_clone_depth=0 or explicit fetch
    IS_NEWER=false
    if git merge-base --is-ancestor "$NEWEST_SHA" "$sha" 2>/dev/null; then
        # Method 1: current newest is ancestor of this sha → this sha is newer (descendant)
        IS_NEWER=true
    elif ! git merge-base --is-ancestor "$sha" "$NEWEST_SHA" 2>/dev/null; then
        # Method 2 Fallback: Neither is ancestor (unrelated branches or shallow clone)
        # Use buildNumber as proxy (higher = queued later = newer)
        if [ "$build_num" -gt "$NEWEST_BUILD_NUM" ]; then
            IS_NEWER=true
        fi
    # else: this sha is ancestor of current newest → current newest stays
    fi

    if [ "$IS_NEWER" = true ]; then
        NEWEST_SHA="$sha"
        NEWEST_BUILD_NUM="$build_num"
    fi
done

echo "check-queue: newest commit is sha=${NEWEST_SHA} buildNumber=${NEWEST_BUILD_NUM}"

# ── Decide: continue or skip ─────────────────────────────────────────────────
if [ "$NEWEST_SHA" != "$SELF_SHA" ]; then
    # Self is stale — a newer commit is queued. Skip this build to save time.
    echo "check-queue: self is NOT the newest commit; skipping (newer SHA ${NEWEST_SHA} pending)"

    # Stop other older queued builds (not the winner, not self)
    # Why stop older builds? They're also stale. No point letting them sit in queue.
    for sha in "${!BUILD_MAP[@]}"; do
        if [ "$sha" == "$NEWEST_SHA" ]; then
            continue  # Don't stop the winner (it will apply the latest changes)
        fi

        build_id=$(echo "${BUILD_MAP[$sha]}" | cut -d'|' -f1)
        if [ "$build_id" != "$SELF_BUILD_ID" ]; then
            echo "check-queue: stopping older queued build ${build_id}"
            aws codebuild stop-build --id "$build_id" >/dev/null 2>&1 || true
        fi
    done

    # Exit 0 = skip this build (not an error — skipping is expected behavior)
    # CRITICAL: This script MUST be sourced (not executed as subprocess) so
    # 'exit 0' kills the parent shell and stops the entire buildspec phase.
    # See header documentation for the source vs. execute difference.
    # OPEN ITEM (spike validation): confirm exit 0 here short-circuits the
    # combined buildspec when sourced in a multi-line block.
    exit 0
fi

# Self IS the newest commit — we're the winner. Proceed to terraform apply.

# Self is the newest — stop all other queued builds and continue
echo "check-queue: self is the newest commit; stopping older queued builds and continuing"

for sha in "${!BUILD_MAP[@]}"; do
    if [ "$sha" == "$SELF_SHA" ]; then
        continue  # Don't stop self
    fi

    build_id=$(echo "${BUILD_MAP[$sha]}" | cut -d'|' -f1)
    echo "check-queue: stopping older queued build ${build_id}"
    aws codebuild stop-build --id "$build_id" >/dev/null 2>&1 || true
done

echo "check-queue: proceeding to terraform apply"
# Return/continue to the buildspec's provision-infra script
