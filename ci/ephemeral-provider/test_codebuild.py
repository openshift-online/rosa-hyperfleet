import unittest
from unittest.mock import patch

from codebuild import BuildMonitor


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


if __name__ == "__main__":
    unittest.main()
