import logging
import time

import boto3

from __init__ import BUILD_COMPLETION_TIMEOUT, POLL_INTERVAL
from codebuild import BuildMonitor, BuildResult

log = logging.getLogger(__name__)


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
                    "actionRevisionType": "COMMIT_ID",
                    "actionRevision": source_version,
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
        while time.monotonic() - monitor_start < timeout:
            response = self.client.get_pipeline_execution(
                pipelineName=pipeline_name,
                pipelineExecutionId=pipeline_execution_id,
            )
            execution = response.get("pipelineExecution", {})
            status = execution.get("status", "Unknown")
            log.info("Pipeline %s execution status: %s", pipeline_execution_id, status)

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
