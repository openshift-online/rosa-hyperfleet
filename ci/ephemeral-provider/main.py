#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = ["boto3", "PyYAML"]
# ///
"""
Ephemeral environment manager for ROSA Regional Platform CI.

Provisions an ephemeral environment or tears one down. Designed for multi-step
CI pipelines where provision, tests, and teardown are separate steps:

    # Step 1: Provision
    BUILD_ID=abc123 ./ci/ephemeral-provider/main.py

    # Step 2: Run tests (separate CI step, same BUILD_ID)

    # Step 3: Teardown
    BUILD_ID=abc123 ./ci/ephemeral-provider/main.py --teardown

If BUILD_ID is not set, a random ID is generated and printed so it can be
passed to subsequent steps.
"""

import argparse
import hashlib
import logging
import os
import re
import sys
import uuid
from pathlib import Path

from __init__ import TARGET_ENVIRONMENT
from orchestrator import EphemeralEnvOrchestrator, discover_region

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def make_ci_prefix() -> str:
    """Generate a CI prefix from BUILD_ID (hashed) or a random UUID.

    BUILD_ID is hashed to avoid collisions between consecutive IDs, then
    truncated to 6 characters for AWS resource name compatibility.
    """
    build_id = os.environ.get("BUILD_ID", "")
    if build_id:
        # Hash the BUILD_ID to avoid collisions with consecutive IDs
        hash_digest = hashlib.sha256(build_id.encode()).hexdigest()
        short_id = hash_digest[:6]
    else:
        short_id = uuid.uuid4().hex[:6]
    return f"ci-{short_id}"


def main():
    parser = argparse.ArgumentParser(description="Ephemeral environment manager for ROSA Regional Platform")
    teardown_group = parser.add_mutually_exclusive_group()
    teardown_group.add_argument(
        "--teardown",
        action="store_true",
        help="Tear down a previously provisioned ephemeral environment",
    )
    teardown_group.add_argument(
        "--teardown-fire-and-forget",
        action="store_true",
        help="Start teardown and exit immediately without waiting for completion",
    )
    teardown_group.add_argument(
        "--resync",
        action="store_true",
        help="Resync the CI branch by rebasing onto the latest source branch",
    )
    parser.add_argument(
        "--repo",
        default=os.environ.get("REPOSITORY_URL", "openshift-online/rosa-regional-platform"),
        help="GitHub repository in owner/name format (default: from REPOSITORY_URL env var)",
    )
    parser.add_argument(
        "--branch",
        default=os.environ.get("REPOSITORY_BRANCH", "main"),
        help="Source branch to test (default: from REPOSITORY_BRANCH env var)",
    )
    parser.add_argument(
        "--creds-dir",
        default=os.environ.get("CREDS_DIR", "/var/run/rosa-credentials/"),
        help="Directory containing CI credentials (optional if credentials are passed as env vars)",
    )
    parser.add_argument(
        "--override-dir",
        default=os.environ.get("EPHEMERAL_OVERRIDE_DIR", ""),
        help="Path to local config overrides directory that replaces config/ephemeral/ "
             "(default: from EPHEMERAL_OVERRIDE_DIR env var)",
    )
    parser.add_argument(
        "--provision-override-file",
        action="append",
        default=[],
        metavar="TARGET:OVERRIDE",
        help="Deep-merge a YAML override file into a repo file before committing. "
             "Format: <target-path>:<override-file>. Can be specified multiple times. "
             "List items are matched by 'name' key. "
             "Example: argocd/config/regional-cluster/platform-api/values.yaml:override.yaml",
    )
    parser.add_argument(
        "--save-regional-state",
        metavar="PATH",
        help="Save RC terraform outputs (JSON) to PATH after provisioning",
    )
    args = parser.parse_args()

    # Normalize repo format (strip github.com prefix and .git suffix if present)
    repo = re.sub(r".*github\.com/", "", args.repo)
    repo = re.sub(r"\.git$", "", repo)

    is_teardown = args.teardown or args.teardown_fire_and_forget

    if (is_teardown or args.resync) and not os.environ.get("BUILD_ID"):
        log.error("BUILD_ID must be set for %s (needed to identify the ephemeral environment)",
                   "resync" if args.resync else "teardown")
        sys.exit(1)

    # When BUILD_ID is not set, generate one and export it so make_ci_prefix()
    # hashes it consistently. This lets the logged teardown hint work correctly.
    build_id = os.environ.get("BUILD_ID", "")
    if not build_id:
        build_id = uuid.uuid4().hex[:8]
        os.environ["BUILD_ID"] = build_id

    ci_prefix = make_ci_prefix()
    log.info("CI prefix: %s (BUILD_ID: %s)", ci_prefix, build_id)

    # Discover region from config files (override dir takes precedence).
    # For teardown, region is discovered from the CI branch after checkout
    # (inside the orchestrator), so we pass a placeholder here.
    override_dir = args.override_dir or None
    if is_teardown:
        region = ""  # discovered from CI branch in orchestrator.teardown()
    else:
        if override_dir and Path(override_dir).exists():
            env_config_dir = Path(override_dir)
        else:
            workspace = Path(os.environ.get("WORKSPACE_DIR", "."))
            env_config_dir = workspace / "config" / TARGET_ENVIRONMENT
        region = discover_region(env_config_dir)
        log.info("Region: %s (from %s)", region, env_config_dir)

    # Parse --provision-override-file args into (target_path, override_file) tuples
    provision_overrides = []
    for entry in args.provision_override_file:
        if ":" not in entry:
            log.error("Invalid --provision-override-file format (expected target:override): %s", entry)
            sys.exit(1)
        target, override = entry.split(":", 1)
        if not target.strip() or not override.strip():
            log.error("Invalid --provision-override-file: target and override must both be non-empty: %s", entry)
            sys.exit(1)
        provision_overrides.append((target, override))

    env = EphemeralEnvOrchestrator(
        repo=repo,
        branch=args.branch,
        creds_dir=args.creds_dir,
        region=region,
        ci_prefix=ci_prefix,
        override_dir=override_dir,
        provision_overrides=provision_overrides,
    )

    try:
        if args.resync:
            env.resync()
            log.info("")
            log.info("==========================================")
            log.info("Resync completed successfully!")
            log.info("==========================================")
        elif is_teardown:
            env.teardown(fire_and_forget=args.teardown_fire_and_forget)
            log.info("")
            log.info("==========================================")
            log.info("Teardown completed successfully!")
            log.info("==========================================")
        else:
            env.provision(save_state=args.save_regional_state)
            # Write discovered region to output dir so the Makefile can capture it
            if args.save_regional_state:
                region_file = Path(args.save_regional_state).parent / "region"
                region_file.write_text(region)
            log.info("")
            log.info("==========================================")
            log.info("Provisioning completed successfully!")
            log.info("==========================================")
            log.info("")
            log.info("To tear down this environment, run:")
            log.info("")
            log.info("    BUILD_ID=%s ./ci/ephemeral-provider/main.py --teardown", build_id)
            log.info("")
    except Exception:
        log.exception("Ephemeral environment %s failed",
                       "resync" if args.resync else "teardown" if is_teardown else "provision")
        sys.exit(1)


if __name__ == "__main__":
    main()
