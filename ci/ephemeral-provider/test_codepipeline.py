import unittest
from unittest.mock import Mock

from botocore.exceptions import ClientError
from codepipeline import (
    PipelineFailure,
    PipelineMonitor,
    _codepipeline_glob_match,
)


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


class CodePipelineGlobTest(unittest.TestCase):
    def test_brace_alternation_matches_each_branch(self):
        pattern = "terraform/config/{management-cluster,kube-applier-dynamodb-provisioning}/**"
        self.assertTrue(
            _codepipeline_glob_match(
                "terraform/config/management-cluster/main.tf", pattern
            )
        )
        self.assertTrue(
            _codepipeline_glob_match(
                "terraform/config/kube-applier-dynamodb-provisioning/x/y.tf", pattern
            )
        )
        self.assertFalse(
            _codepipeline_glob_match("terraform/config/regional-cluster/main.tf", pattern)
        )

    def test_single_star_does_not_cross_separator(self):
        self.assertFalse(_codepipeline_glob_match("a/b/c.txt", "a/*"))
        self.assertTrue(_codepipeline_glob_match("a/b.txt", "a/*"))

    def test_globstar_matches_zero_or_more_segments(self):
        self.assertTrue(_codepipeline_glob_match("a/b", "a/**/b"))
        self.assertTrue(_codepipeline_glob_match("a/x/y/b", "a/**/b"))
        self.assertTrue(_codepipeline_glob_match("a/file", "a/**"))

    def test_push_trigger_matches_real_rc_filter(self):
        pipeline = {
            "triggers": [
                {
                    "providerType": "CodeStarSourceConnection",
                    "gitConfiguration": {
                        "push": [
                            {
                                "branches": {"includes": ["eph-abc"]},
                                "filePaths": {
                                    "includes": [
                                        "terraform/config/regional-cluster/**"
                                    ]
                                },
                            }
                        ]
                    },
                }
            ]
        }
        self.assertTrue(
            PipelineMonitor.push_trigger_matches(
                pipeline, "eph-abc", ["terraform/config/regional-cluster/main.tf"]
            )
        )
        self.assertFalse(
            PipelineMonitor.push_trigger_matches(
                pipeline, "eph-abc", ["docs/README.md"]
            )
        )


class HasSuccessfulExecutionTest(unittest.TestCase):
    def _monitor(self, summaries):
        client = Mock()
        client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": summaries
        }
        session = Mock()
        session.client.return_value = client
        return PipelineMonitor(session)

    def test_newest_failed_does_not_fall_back_to_older_success(self):
        monitor = self._monitor(
            [
                {
                    "pipelineExecutionId": "newer",
                    "status": "Failed",
                    "startTime": "2026-02-02",
                    "sourceRevisions": [{"actionName": "Source", "revisionId": "b" * 40}],
                },
                {
                    "pipelineExecutionId": "older",
                    "status": "Succeeded",
                    "startTime": "2026-01-01",
                    "sourceRevisions": [{"actionName": "Source", "revisionId": "a" * 40}],
                },
            ]
        )
        self.assertIsNone(monitor.has_successful_execution("cluster-pipeline"))

    def test_skips_nonterminal_then_returns_newest_success(self):
        monitor = self._monitor(
            [
                {
                    "pipelineExecutionId": "running",
                    "status": "InProgress",
                    "startTime": "2026-03-03",
                    "sourceRevisions": [{"actionName": "Source", "revisionId": "c" * 40}],
                },
                {
                    "pipelineExecutionId": "newest-success",
                    "status": "Succeeded",
                    "startTime": "2026-02-02",
                    "sourceRevisions": [{"actionName": "Source", "revisionId": "b" * 40}],
                },
            ]
        )
        self.assertEqual(
            monitor.has_successful_execution("cluster-pipeline"),
            ("newest-success", "b" * 40),
        )


if __name__ == "__main__":
    unittest.main()
