import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from codebuild import BuildFailure, BuildMonitor


class ResourceNotFoundException(Exception):
    pass


class FakeClient:
    class exceptions:
        ResourceNotFoundException = ResourceNotFoundException

    def __init__(self, responses):
        self.responses = iter(responses)

    def batch_get_builds(self, ids):
        return next(self.responses)


class FakeSession:
    def __init__(self, client):
        self.client_instance = client

    def client(self, service_name):
        assert service_name == "codebuild"
        return self.client_instance


class BuildMonitorTests(unittest.TestCase):
    def test_waits_for_resolved_source_version_while_build_is_active(self):
        desired_sha = "a" * 40
        build_id = "project:build-id"
        client = FakeClient(
            [
                {
                    "builds": [
                        {
                            "id": build_id,
                            "buildStatus": "IN_PROGRESS",
                            "sourceVersion": desired_sha,
                        }
                    ]
                },
                {
                    "builds": [
                        {
                            "id": build_id,
                            "buildStatus": "SUCCEEDED",
                            "sourceVersion": desired_sha,
                            "resolvedSourceVersion": desired_sha,
                            "exportedEnvironmentVariables": [
                                {"name": "APPLIED", "value": "true"},
                                {"name": "APPLIED_SHA", "value": desired_sha},
                            ],
                        }
                    ]
                },
            ]
        )
        monitor = BuildMonitor(FakeSession(client))

        with patch("codebuild.time.sleep"):
            monitor.wait_for_build(build_id, desired_sha, timeout=1)

    def test_rejects_active_build_requested_for_different_sha(self):
        desired_sha = "a" * 40
        client = FakeClient(
            [
                {
                    "builds": [
                        {
                            "id": "project:build-id",
                            "buildStatus": "IN_PROGRESS",
                            "sourceVersion": "b" * 40,
                        }
                    ]
                }
            ]
        )
        monitor = BuildMonitor(FakeSession(client))

        with self.assertRaisesRegex(RuntimeError, "requested for SHA"):
            monitor.wait_for_build("project:build-id", desired_sha, timeout=1)

    def test_defers_branch_source_version_until_resolution(self):
        desired_sha = "a" * 40
        build_id = "project:build-id"
        client = FakeClient(
            [
                {
                    "builds": [
                        {
                            "id": build_id,
                            "buildStatus": "IN_PROGRESS",
                            "sourceVersion": "refs/heads/main",
                        }
                    ]
                },
                {
                    "builds": [
                        {
                            "id": build_id,
                            "buildStatus": "SUCCEEDED",
                            "sourceVersion": "refs/heads/main",
                            "resolvedSourceVersion": desired_sha,
                            "exportedEnvironmentVariables": [
                                {"name": "APPLIED", "value": "true"},
                                {"name": "APPLIED_SHA", "value": desired_sha},
                            ],
                        }
                    ]
                },
            ]
        )
        monitor = BuildMonitor(FakeSession(client))

        with patch("codebuild.time.sleep"):
            monitor.wait_for_build(build_id, desired_sha, timeout=1)

    def test_logs_phase_progress_and_build_summary(self):
        desired_sha = "a" * 40
        build_id = "project:build-id"
        start = datetime.now(timezone.utc)
        client = FakeClient(
            [
                {
                    "builds": [
                        {
                            "id": build_id,
                            "buildStatus": "IN_PROGRESS",
                            "currentPhase": "BUILD",
                            "sourceVersion": desired_sha,
                            "phases": [
                                {
                                    "phaseType": "INSTALL",
                                    "phaseStatus": "SUCCEEDED",
                                    "startTime": start,
                                    "endTime": start + timedelta(seconds=2),
                                },
                                {
                                    "phaseType": "BUILD",
                                    "startTime": start + timedelta(seconds=2),
                                },
                            ],
                        }
                    ]
                },
                {
                    "builds": [
                        {
                            "id": build_id,
                            "buildStatus": "SUCCEEDED",
                            "sourceVersion": desired_sha,
                            "resolvedSourceVersion": desired_sha,
                            "startTime": start,
                            "endTime": start + timedelta(seconds=8),
                            "phases": [
                                {
                                    "phaseType": "INSTALL",
                                    "phaseStatus": "SUCCEEDED",
                                    "startTime": start,
                                    "endTime": start + timedelta(seconds=2),
                                },
                                {
                                    "phaseType": "BUILD",
                                    "phaseStatus": "SUCCEEDED",
                                    "startTime": start + timedelta(seconds=2),
                                    "endTime": start + timedelta(seconds=7),
                                },
                                {
                                    "phaseType": "POST_BUILD",
                                    "phaseStatus": "SUCCEEDED",
                                    "startTime": start + timedelta(seconds=7),
                                    "endTime": start + timedelta(seconds=8),
                                },
                            ],
                            "exportedEnvironmentVariables": [
                                {"name": "APPLIED", "value": "true"},
                                {"name": "APPLIED_SHA", "value": desired_sha},
                            ],
                        }
                    ]
                },
            ]
        )
        monitor = BuildMonitor(FakeSession(client))

        with (
            patch("codebuild.time.sleep"),
            patch("codebuild.BUILD_PROGRESS_LOG_INTERVAL", 0),
            self.assertLogs("codebuild", level="INFO") as captured,
        ):
            monitor.wait_for_build(build_id, desired_sha, timeout=1)

        output = "\n".join(captured.output)
        self.assertIn("phase INSTALL: SUCCEEDED", output)
        self.assertIn("phase BUILD: IN_PROGRESS", output)
        self.assertIn("still IN_PROGRESS: phase=BUILD", output)
        self.assertIn("summary: status=SUCCEEDED, total duration=8s", output)
        self.assertIn("summary: phase=BUILD, status=SUCCEEDED, duration=5s", output)

    def test_reports_stopped_build_context_without_guessing_cause(self):
        desired_sha = "a" * 40
        build_id = "project:build-id"
        client = FakeClient(
            [
                {
                    "builds": [
                        {
                            "id": build_id,
                            "buildStatus": "STOPPED",
                            "currentPhase": "BUILD",
                            "initiator": "codebuild/project",
                            "sourceVersion": desired_sha,
                            "phases": [
                                {
                                    "phaseType": "BUILD",
                                    "phaseStatus": "STOPPED",
                                    "contexts": [
                                        {
                                            "statusCode": "USER_INITIATED",
                                            "message": "Build stopped by user",
                                        }
                                    ],
                                }
                            ],
                        }
                    ]
                }
            ]
        )
        monitor = BuildMonitor(FakeSession(client))

        with self.assertRaises(BuildFailure) as raised:
            monitor.wait_for_build(build_id, desired_sha, timeout=1)

        self.assertIn("status STOPPED", str(raised.exception))
        self.assertIn("initiator=codebuild/project", str(raised.exception))
        self.assertIn("Build stopped by user", str(raised.exception))
        self.assertEqual(raised.exception.result.status, "STOPPED")


if __name__ == "__main__":
    unittest.main()
