import unittest
from unittest.mock import Mock

from codepipeline import PipelineMonitor


class PipelineMonitorTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
