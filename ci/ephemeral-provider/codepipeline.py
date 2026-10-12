import logging
import time
from dataclasses import dataclass

import boto3
from botocore.exceptions import ClientError

from __init__ import BUILD_COMPLETION_TIMEOUT, POLL_INTERVAL
from codebuild import BuildMonitor, BuildResult

log = logging.getLogger(__name__)
PIPELINE_LOOKUP_GRACE_PERIOD = 300
PIPELINE_LOOKUP_NOT_FOUND_ERRORS = {
    "PipelineExecutionNotFoundException",
    "PipelineNotFoundException",
}


@dataclass
class _PipelineWaitState:
    pipeline_name: str
    execution_id: str
    status: str = "PENDING"
    done: bool = False
    not_found_since: float | None = None
    not_found_code: str | None = None
    build_id: str | None = None
    error: str | None = None
    failure_logged: bool = False


class PipelineFailure(RuntimeError):
    """A terminal CodePipeline execution failure."""


class PipelineMonitor:
    """Start and monitor CodePipeline executions backed by CodeBuild actions."""

    def __init__(self, session: boto3.Session):
        self.session = session
        self.client = session.client("codepipeline")
        self.build_monitor = BuildMonitor(session)

    @staticmethod
    def pipeline_name(project_name: str) -> str:
        return f"{project_name}-pipeline"

    def start_pipeline(
        self,
        pipeline_name: str,
        source_version: str,
        environment_variables: dict[str, str] | None = None,
    ) -> str:
        """Start a pipeline at a commit, optionally setting pipeline variables."""
        request = {
            "name": pipeline_name,
            "sourceRevisions": [
                {
                    "actionName": "Source",
                    "revisionType": "COMMIT_ID",
                    "revisionValue": source_version,
                }
            ],
        }
        if environment_variables:
            request["variables"] = [
                {"name": name, "value": value}
                for name, value in environment_variables.items()
            ]

        try:
            response = self.client.start_pipeline_execution(**request)
        except self.client.exceptions.PipelineNotFoundException as exc:
            raise RuntimeError(
                f"CodePipeline not found: {pipeline_name}. "
                "Ensure provision-cluster-resources.sh ran successfully."
            ) from exc

        execution_id = response["pipelineExecutionId"]
        log.info(
            "Started pipeline %s at SHA %s: %s",
            pipeline_name,
            source_version[:7],
            execution_id,
        )
        return execution_id

    def active_pipelines(self, pipeline_names: list[str]) -> list[str]:
        """Return active execution IDs for the selected pipelines."""
        active = []
        for pipeline_name in pipeline_names:
            try:
                response = self.client.list_pipeline_executions(
                    pipelineName=pipeline_name,
                    maxResults=100,
                )
            except self.client.exceptions.PipelineNotFoundException:
                continue
            for execution in response.get("pipelineExecutionSummaries", []):
                if execution.get("status") in ("InProgress", "Stopping"):
                    active.append(
                        f"{pipeline_name}:{execution.get('pipelineExecutionId', 'unknown')}"
                    )
        return active

    def _build_execution_id(self, pipeline_name: str, pipeline_execution_id: str) -> str | None:
        response = self.client.list_action_executions(
            pipelineName=pipeline_name,
            filter={"pipelineExecutionId": pipeline_execution_id},
            maxResults=100,
        )
        for action in response.get("actionExecutionDetails", []):
            if action.get("actionName") != "ApplyInfrastructure":
                continue
            result = (action.get("output") or {}).get("executionResult") or {}
            external_id = result.get("externalExecutionId")
            if external_id:
                return external_id
        return None

    def wait_for_pipelines(
        self,
        builds: list[tuple[str, str]],
        desired_sha: str,
        timeout: int = BUILD_COMPLETION_TIMEOUT,
    ) -> dict[str, BuildResult]:
        """Poll pipelines in caller order, then validate their CodeBuild results.

        Each tuple contains a project name and its pipeline execution ID. The
        caller supplies RC first, followed by MC projects, so each poll cycle
        reports the regional pipeline before management-cluster pipelines.
        """
        states = {
            project_name: _PipelineWaitState(
                pipeline_name=self.pipeline_name(project_name),
                execution_id=execution_id,
            )
            for project_name, execution_id in builds
        }
        monitor_start = time.monotonic()

        while not all(state.done for state in states.values()):
            for index, (project_name, _) in enumerate(builds):
                state = states[project_name]
                role = "RC" if index == 0 else "MC"

                if not state.done:
                    try:
                        response = self.client.get_pipeline_execution(
                            pipelineName=state.pipeline_name,
                            pipelineExecutionId=state.execution_id,
                        )
                    except ClientError as exc:
                        error_code = exc.response.get("Error", {}).get("Code", "Unknown")
                        if error_code in PIPELINE_LOOKUP_NOT_FOUND_ERRORS:
                            now = time.monotonic()
                            if state.not_found_since is None:
                                state.not_found_since = now
                            state.not_found_code = error_code
                            not_found_duration = now - state.not_found_since
                            if not_found_duration >= PIPELINE_LOOKUP_GRACE_PERIOD:
                                state.status = "LOOKUP_FAILED"
                                state.error = (
                                    f"AWS returned {state.not_found_code} for pipeline "
                                    f"{state.pipeline_name} execution "
                                    f"{state.execution_id}; it remained unavailable after "
                                    f"{int(not_found_duration)}s"
                                )
                                state.done = True
                            else:
                                state.status = (
                                    f"LOOKUP_PENDING ({int(not_found_duration)}/"
                                    f"{PIPELINE_LOOKUP_GRACE_PERIOD}s)"
                                )
                        else:
                            state.status = "ERROR"
                            state.error = (
                                f"Unable to read pipeline {state.pipeline_name} execution "
                                f"{state.execution_id} status (AWS error {error_code}): {exc}"
                            )
                            state.done = True
                    except Exception as exc:
                        state.status = "ERROR"
                        state.error = (
                            f"Unable to read pipeline {state.pipeline_name} execution "
                            f"{state.execution_id} status: {exc}"
                        )
                        state.done = True
                    else:
                        state.not_found_since = None
                        state.not_found_code = None
                        state.status = response.get("pipelineExecution", {}).get(
                            "status", "Unknown"
                        )
                        if state.status == "Succeeded":
                            try:
                                state.build_id = self._build_execution_id(
                                    state.pipeline_name, state.execution_id
                                )
                            except Exception as exc:
                                state.status = "ERROR"
                                state.error = (
                                    f"Unable to find the CodeBuild execution for pipeline "
                                    f"{state.pipeline_name}: {exc}"
                                )
                                state.done = True
                            else:
                                if not state.build_id:
                                    state.status = "ERROR"
                                    state.error = (
                                        f"Pipeline {state.pipeline_name} succeeded without "
                                        "a CodeBuild execution ID"
                                    )
                                state.done = True
                        elif state.status in ("Failed", "Stopped", "Superseded"):
                            state.error = (
                                f"Pipeline {state.pipeline_name} execution "
                                f"{state.execution_id} ended with status {state.status}"
                            )
                            state.done = True

                log.info(
                    "%s pipeline %s execution %s status: %s",
                    role,
                    state.pipeline_name,
                    state.execution_id,
                    state.status,
                )
                if state.error and not state.failure_logged:
                    log.error("%s pipeline failure: %s", role, state.error)
                    state.failure_logged = True

            if all(state.done for state in states.values()):
                break

            remaining = timeout - (time.monotonic() - monitor_start)
            if remaining <= 0:
                for index, (project_name, _) in enumerate(builds):
                    state = states[project_name]
                    if state.done:
                        continue
                    role = "RC" if index == 0 else "MC"
                    state.status = "TIMED_OUT"
                    state.error = (
                        f"Pipeline {state.pipeline_name} execution {state.execution_id} "
                        f"did not complete within {timeout}s"
                    )
                    state.done = True
                    log.error("%s pipeline failure: %s", role, state.error)
                    state.failure_logged = True
                break

            time.sleep(min(POLL_INTERVAL, remaining))

        results = {}
        for project_name, execution_id in builds:
            state = states[project_name]
            if state.error:
                results[project_name] = BuildResult(
                    build_id=state.build_id or execution_id,
                    status=state.status.upper().split(" ", 1)[0],
                    total_duration=None,
                    error=state.error,
                )
                continue

            if not state.build_id:
                results[project_name] = BuildResult(
                    build_id=execution_id,
                    status="ERROR",
                    total_duration=None,
                    error=f"Pipeline {state.pipeline_name} has no CodeBuild execution ID",
                )
                continue

            try:
                result = self.build_monitor.wait_for_build(
                    state.build_id,
                    desired_sha,
                    timeout=timeout,
                )
            except Exception as exc:
                result = getattr(exc, "result", None)
                if result is None:
                    result = BuildResult(
                        build_id=state.build_id or execution_id,
                        status="ERROR",
                        total_duration=None,
                        error=str(exc),
                    )
            results[project_name] = result

        return results

    def wait_for_pipeline(
        self,
        pipeline_name: str,
        pipeline_execution_id: str,
        desired_sha: str,
        timeout: int = BUILD_COMPLETION_TIMEOUT,
    ) -> BuildResult:
        """Wait for a pipeline and validate its underlying CodeBuild contract."""
        log.info(
            "Waiting for pipeline %s execution %s (desired SHA: %s)",
            pipeline_name,
            pipeline_execution_id,
            desired_sha[:7],
        )
        monitor_start = time.monotonic()
        execution_not_found_since = None
        execution_not_found_code = None
        while time.monotonic() - monitor_start < timeout:
            try:
                response = self.client.get_pipeline_execution(
                    pipelineName=pipeline_name,
                    pipelineExecutionId=pipeline_execution_id,
                )
            except ClientError as exc:
                error_code = exc.response.get("Error", {}).get("Code", "Unknown")
                if error_code in PIPELINE_LOOKUP_NOT_FOUND_ERRORS:
                    now = time.monotonic()
                    if execution_not_found_since is None:
                        execution_not_found_since = now
                    execution_not_found_code = error_code
                    not_found_duration = now - execution_not_found_since
                    if not_found_duration >= PIPELINE_LOOKUP_GRACE_PERIOD:
                        raise PipelineFailure(
                            f"AWS returned {execution_not_found_code} for pipeline "
                            f"{pipeline_name} execution {pipeline_execution_id} "
                            f"and it remained unavailable after {int(not_found_duration)}s"
                        ) from exc
                    log.warning(
                        "Pipeline %s execution %s is not visible yet; retrying in %ds "
                        "(%.0fs elapsed)",
                        pipeline_name,
                        pipeline_execution_id,
                        POLL_INTERVAL,
                        not_found_duration,
                    )
                    time.sleep(POLL_INTERVAL)
                    continue

                raise PipelineFailure(
                    f"Unable to read pipeline {pipeline_name} execution "
                    f"{pipeline_execution_id} status (AWS error {error_code}): {exc}"
                ) from exc

            execution_not_found_since = None
            execution_not_found_code = None
            execution = response.get("pipelineExecution", {})
            status = execution.get("status", "Unknown")
            log.info(
                "Pipeline %s execution %s status: %s",
                pipeline_name,
                pipeline_execution_id,
                status,
            )

            if status == "Succeeded":
                build_id = self._build_execution_id(pipeline_name, pipeline_execution_id)
                if not build_id:
                    raise PipelineFailure(
                        f"Pipeline {pipeline_name} succeeded without a CodeBuild execution ID"
                    )
                return self.build_monitor.wait_for_build(build_id, desired_sha, timeout)

            if status in ("Failed", "Stopped", "Superseded"):
                raise PipelineFailure(
                    f"Pipeline {pipeline_name} execution {pipeline_execution_id} ended with "
                    f"status {status}"
                )

            time.sleep(POLL_INTERVAL)

        raise TimeoutError(
            f"Pipeline {pipeline_name} execution {pipeline_execution_id} did not complete "
            f"within {timeout}s"
        )

    @staticmethod
    def _format_duration(seconds: float | None) -> str:
        return BuildMonitor._format_duration(seconds)
