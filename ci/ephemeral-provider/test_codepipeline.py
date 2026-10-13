import unittest
from unittest.mock import Mock

from botocore.exceptions import ClientError
from codepipeline import PipelineFailure, PipelineMonitor


class PipelineMonitorTest(unittest.TestCase):
    def test_missing_pipelines_returns_only_not_found_names(self):
        codepipeline_client = Mock()
        codepipeline_client.get_pipeline.side_effect = [
            {"pipeline": {"name": "existing-pipeline"}},
            ClientError(
                {"Error": {"Code": "PipelineNotFoundException"}},
                "GetPipeline",
            ),
        ]
        session = Mock()
        session.client.return_value = codepipeline_client

        monitor = PipelineMonitor(session)

        self.assertEqual(
            monitor.missing_pipelines(["existing-pipeline", "new-pipeline"]),
            ["new-pipeline"],
        )

    def test_wait_for_creation_execution_uses_matching_source_revision(self):
        codepipeline_client = Mock()
        codepipeline_client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": [
                {
                    "pipelineExecutionId": "create-execution",
                    "sourceRevisions": [
                        {"actionName": "Source", "revisionId": "a" * 40}
                    ],
                }
            ]
        }
        session = Mock()
        session.client.return_value = codepipeline_client

        monitor = PipelineMonitor(session)

        self.assertEqual(
            monitor.wait_for_creation_execution("new-pipeline", "a" * 40),
            "create-execution",
        )

    def test_start_pipeline_uses_supported_source_revision_fields(self):
        codepipeline_client = Mock()
        codepipeline_client.start_pipeline_execution.return_value = {
            "pipelineExecutionId": "execution-123"
        }
        session = Mock()
        session.client.side_effect = lambda service: (
            codepipeline_client if service == "codepipeline" else Mock()
        )

        monitor = PipelineMonitor(session)
        execution_id = monitor.start_pipeline("cluster-pipeline", "a" * 40)

        self.assertEqual(execution_id, "execution-123")
        codepipeline_client.start_pipeline_execution.assert_called_once_with(
            name="cluster-pipeline",
            sourceRevisions=[
                {
                    "actionName": "Source",
                    "revisionType": "COMMIT_ID",
                    "revisionValue": "a" * 40,
                }
            ],
        )

    def test_start_or_reuse_pipeline_reuses_active_execution_at_requested_sha(self):
        codepipeline_client = Mock()
        codepipeline_client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": [
                {
                    "pipelineExecutionId": "active-execution",
                    "status": "InProgress",
                    "sourceRevisions": [
                        {"actionName": "Source", "revisionId": "a" * 40}
                    ],
                }
            ]
        }
        session = Mock()
        session.client.return_value = codepipeline_client

        monitor = PipelineMonitor(session)

        self.assertEqual(
            monitor.start_or_reuse_pipeline("cluster-pipeline", "a" * 40),
            "active-execution",
        )
        codepipeline_client.start_pipeline_execution.assert_not_called()

    def test_start_or_reuse_pipeline_rejects_active_execution_at_other_sha(self):
        codepipeline_client = Mock()
        codepipeline_client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": [
                {
                    "pipelineExecutionId": "active-execution",
                    "status": "InProgress",
                    "sourceRevisions": [
                        {"actionName": "Source", "revisionId": "b" * 40}
                    ],
                }
            ]
        }
        session = Mock()
        session.client.return_value = codepipeline_client

        monitor = PipelineMonitor(session)

        with self.assertRaisesRegex(PipelineFailure, "different or unavailable revision"):
            monitor.start_or_reuse_pipeline("cluster-pipeline", "a" * 40)
        codepipeline_client.start_pipeline_execution.assert_not_called()

    def test_cancelled_pipeline_is_terminal(self):
        codepipeline_client = Mock()
        codepipeline_client.get_pipeline_execution.return_value = {
            "pipelineExecution": {"status": "Cancelled"}
        }
        session = Mock()
        session.client.side_effect = lambda service: (
            codepipeline_client if service == "codepipeline" else Mock()
        )

        monitor = PipelineMonitor(session)
        results = monitor.wait_for_pipelines(
            [("eph-test-regional", "execution-123")],
            desired_sha="a" * 40,
            timeout=1,
        )

        self.assertEqual(results["eph-test-regional"].status, "CANCELLED")
        self.assertIn("Cancelled", results["eph-test-regional"].error)
        codepipeline_client.get_pipeline_execution.assert_called_once_with(
            pipelineName="eph-test-regional-pipeline",
            pipelineExecutionId="execution-123",
        )

    def test_cancelled_single_pipeline_raises_failure(self):
        codepipeline_client = Mock()
        codepipeline_client.get_pipeline_execution.return_value = {
            "pipelineExecution": {"status": "Cancelled"}
        }
        session = Mock()
        session.client.side_effect = lambda service: (
            codepipeline_client if service == "codepipeline" else Mock()
        )

        monitor = PipelineMonitor(session)
        with self.assertRaisesRegex(PipelineFailure, "status Cancelled"):
            monitor.wait_for_pipeline(
                "eph-test-regional-pipeline",
                "execution-123",
                desired_sha="a" * 40,
                timeout=1,
            )


if __name__ == "__main__":
    unittest.main()
