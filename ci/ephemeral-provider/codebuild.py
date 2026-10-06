import logging
import time

import boto3

from __init__ import POLL_INTERVAL, BUILD_COMPLETION_TIMEOUT

log = logging.getLogger(__name__)

WEBHOOK_DISCOVERY_ATTEMPTS = 5
WEBHOOK_DISCOVERY_INTERVAL = 2


class BuildMonitor:
    """Monitor AWS CodeBuild builds.

    Replaces CodePipeline monitoring with direct CodeBuild API calls. The provider
    explicitly StartBuilds each project pinned to a git SHA and waits on the returned
    build ID, gating on the APPLIED/APPLIED_SHA success contract.

    No prefix discovery — project names are deterministic (read from rendered config).
    """

    def __init__(self, session: boto3.Session):
        """
        Args:
            session: boto3 Session configured for the target account/region.
        """
        self.session = session
        self.client = session.client("codebuild")

    def start_build(self, project_name: str, source_version: str) -> str:
        """Start a CodeBuild build for a project at a specific git SHA.

        Args:
            project_name: CodeBuild project name (e.g., "eph-abc123-regional").
            source_version: Full git SHA to build (e.g., "a1b2c3d4...").

        Returns:
            Build ID (e.g., "project-name:uuid").
        """
        log.info("Starting build: %s at SHA %s", project_name, source_version[:7])
        try:
            response = self.client.start_build(
                projectName=project_name,
                sourceVersion=source_version,
            )
            build_id = response["build"]["id"]
            log.info("Build started: %s", build_id)
            return build_id
        except self.client.exceptions.ResourceNotFoundException:
            raise RuntimeError(
                f"CodeBuild project not found: {project_name}. "
                "Ensure provision-codebuilds.sh ran successfully."
            )

    def _find_active_build(self, project_name: str, source_version: str) -> str | None:
        """Find an already-running webhook or manually-triggered build at a SHA."""
        response = self.client.list_builds_for_project(
            projectName=project_name,
            sortOrder="DESCENDING",
        )
        build_ids = response.get("ids", [])
        if not build_ids:
            return None

        builds = self.client.batch_get_builds(ids=build_ids).get("builds", [])
        for build in builds:
            if (
                build.get("buildStatus") in ("QUEUED", "IN_PROGRESS")
                and (
                    build.get("resolvedSourceVersion") == source_version
                    or build.get("sourceVersion") == source_version
                )
            ):
                return build["id"]
        return None

    def active_builds(self, project_names: list[str]) -> list[str]:
        """Return IDs of queued or running builds for the given projects."""
        active = []
        for project_name in project_names:
            try:
                response = self.client.list_builds_for_project(
                    projectName=project_name,
                    sortOrder="DESCENDING",
                )
            except self.client.exceptions.ResourceNotFoundException:
                continue

            build_ids = response.get("ids", [])
            if not build_ids:
                continue

            builds = self.client.batch_get_builds(ids=build_ids).get("builds", [])
            active.extend(
                build["id"]
                for build in builds
                if build.get("buildStatus") in ("QUEUED", "IN_PROGRESS")
            )
        return active

    def start_or_reuse_build(self, project_name: str, source_version: str) -> str:
        """Reuse a webhook build at the requested SHA or start one explicitly.

        Resync pushes can trigger the project's webhook immediately before the
        provider reaches this point. Reusing that build avoids starting a
        duplicate build; the explicit StartBuild fallback preserves operation
        when webhook delivery is delayed or unavailable.
        """
        for attempt in range(WEBHOOK_DISCOVERY_ATTEMPTS):
            build_id = self._find_active_build(project_name, source_version)
            if build_id:
                log.info("Reusing active build at SHA %s: %s", source_version[:7], build_id)
                return build_id
            if attempt < WEBHOOK_DISCOVERY_ATTEMPTS - 1:
                time.sleep(WEBHOOK_DISCOVERY_INTERVAL)

        return self.start_build(project_name, source_version)

    def wait_for_build(
        self,
        build_id: str,
        desired_sha: str,
        timeout: int = BUILD_COMPLETION_TIMEOUT,
    ):
        """Wait for a CodeBuild build to complete and verify the success contract.

        Gates on: buildStatus=SUCCEEDED && APPLIED=="true" && APPLIED_SHA==desired_sha.
        Rejects skip builds (APPLIED!="true") and STOPPED builds because the
        requested SHA was not applied by that build.

        Args:
            build_id: CodeBuild build ID (returned by start_build).
            desired_sha: Expected git SHA (must match sourceVersion, resolvedSourceVersion,
                and APPLIED_SHA when those values are available).
            timeout: Max seconds to wait.

        Raises:
            TimeoutError: Build did not complete within timeout.
            RuntimeError: Build failed, or success contract not met.
        """
        log.info(
            "Waiting for build %s (desired SHA: %s, timeout: %ds)",
            build_id,
            desired_sha[:7],
            timeout,
        )
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                response = self.client.batch_get_builds(ids=[build_id])
                builds = response.get("builds", [])
                if not builds:
                    raise RuntimeError(f"Build not found: {build_id}")

                build = builds[0]
                status = build.get("buildStatus")
                source_sha = build.get("sourceVersion", "")
                resolved_sha = build.get("resolvedSourceVersion", "")

                # sourceVersion is the requested version and is available before the
                # source download. It lets us reject an unexpected build early without
                # requiring resolvedSourceVersion, which CodeBuild only populates after
                # DOWNLOAD_SOURCE.
                if self._is_full_commit_sha(source_sha) and source_sha.lower() != desired_sha.lower():
                    raise RuntimeError(
                        f"Build {build_id} was requested for SHA {source_sha[:7]}, "
                        f"expected {desired_sha[:7]}."
                    )

                if status in ("IN_PROGRESS", "QUEUED"):
                    # resolvedSourceVersion is not available until DOWNLOAD_SOURCE
                    # completes, so an empty value here is expected.
                    time.sleep(POLL_INTERVAL)
                    continue

                # Terminal statuses
                if status == "SUCCEEDED":
                    # For GitHub/CodeConnections, the resolved commit is available
                    # once the build reaches a terminal state.
                    if not resolved_sha:
                        raise RuntimeError(
                            f"Build {build_id} succeeded without resolvedSourceVersion; "
                            "cannot verify the requested SHA."
                        )

                    if resolved_sha != desired_sha:
                        raise RuntimeError(
                            f"Build {build_id} resolved to SHA {resolved_sha[:7]}, "
                            f"expected {desired_sha[:7]}. This should not happen when "
                            "StartBuild is pinned to the pushed SHA."
                        )

                    # Check the success contract: APPLIED=="true" && APPLIED_SHA==desired_sha.
                    # A skipped build is not a successful provisioning result.
                    applied = self._exported_var(build, "APPLIED")
                    applied_sha = self._exported_var(build, "APPLIED_SHA")

                    if applied != "true":
                        raise RuntimeError(
                            f"Build {build_id} succeeded but APPLIED={applied!r} (not 'true'). "
                            "The CodeBuild success contract was not satisfied; the build "
                            "may have been skipped by check-queue.sh or failed to export "
                            "its status variables."
                        )

                    if applied_sha != desired_sha:
                        applied_sha_display = (applied_sha or "")[:7]
                        raise RuntimeError(
                            f"Build {build_id} succeeded but APPLIED_SHA={applied_sha_display!r}, "
                            f"expected {desired_sha[:7]}. State mismatch."
                        )

                    log.info(
                        "Build %s succeeded: APPLIED=true, APPLIED_SHA=%s",
                        build_id,
                        applied_sha[:7],
                    )
                    return

                elif status == "STOPPED":
                    # Superseded by a newer build (check-queue.sh dedup)
                    raise RuntimeError(
                        f"Build {build_id} was STOPPED (superseded by a newer build). "
                        "Should not happen when we StartBuild the newest SHA."
                    )

                elif status in ("FAILED", "TIMED_OUT", "FAULT"):
                    raise RuntimeError(
                        f"Build {build_id} failed with status {status}. "
                        "Check CloudWatch logs for details."
                    )

                else:
                    raise RuntimeError(f"Unknown build status: {status}")

            except self.client.exceptions.ResourceNotFoundException:
                # Project was deleted mid-teardown → treat as gone
                log.warning(
                    "Build %s project deleted (ResourceNotFoundException) — treating as complete",
                    build_id,
                )
                return

        raise TimeoutError(
            f"Build {build_id} did not complete within {timeout}s. "
            f"Last known status: {status}"
        )

    def delete_project(self, project_name: str):
        """Delete a CodeBuild project (idempotent).

        Used by teardown Phase 2 to remove RC/MC projects directly (replaces
        the GitOps delete_codebuild flow).

        Args:
            project_name: CodeBuild project name.
        """
        log.info("Deleting CodeBuild project: %s", project_name)

        # Delete webhook first (idempotent)
        try:
            self.client.delete_webhook(projectName=project_name)
            log.info("  Webhook deleted: %s", project_name)
        except self.client.exceptions.ResourceNotFoundException:
            log.info("  Webhook already deleted or does not exist")

        # Delete project (idempotent)
        try:
            self.client.delete_project(name=project_name)
            log.info("  Project deleted: %s", project_name)
        except self.client.exceptions.ResourceNotFoundException:
            log.info("  Project already deleted or does not exist")

    @staticmethod
    def _is_full_commit_sha(value: str) -> bool:
        """Return whether a source version is a full hexadecimal commit SHA."""
        return len(value) == 40 and all(char in "0123456789abcdefABCDEF" for char in value)

    @staticmethod
    def _exported_var(build: dict, name: str) -> str | None:
        """Read an exported environment variable from a build.

        Args:
            build: Build object from batch_get_builds.
            name: Variable name (e.g., "APPLIED", "APPLIED_SHA").

        Returns:
            Variable value, or None if not exported.
        """
        exported_vars = build.get("exportedEnvironmentVariables", [])
        for var in exported_vars:
            if var.get("name") == name:
                return var.get("value")
        return None
