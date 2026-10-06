import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from main import write_provision_metadata
from orchestrator import EphemeralEnvOrchestrator


class FakeGit:
    def __init__(self, events, sha="a" * 40):
        self.events = events
        self.sha = sha

    def current_sha(self):
        self.events.append(("current_sha",))
        return self.sha

    def modify_config(self, *args):
        self.events.append(("modify_config",))
        return self.sha


class FakeMonitor:
    def __init__(self, events, failed_projects=None):
        self.events = events
        self.failed_projects = set(failed_projects or ())

    def start_build(self, project_name, source_version, environment_overrides=None):
        self.events.append(("start", project_name, environment_overrides))
        return f"{project_name}:build"

    def wait_for_build(self, build_id, source_version):
        project_name = build_id.split(":", 1)[0]
        self.events.append(("wait", project_name))
        if project_name in self.failed_projects:
            raise RuntimeError(f"{project_name} failed")

    def delete_project(self, project_name):
        self.events.append(("delete", project_name))


def make_orchestrator(events, failed_projects=None):
    orchestrator = EphemeralEnvOrchestrator.__new__(EphemeralEnvOrchestrator)
    orchestrator.region = "us-east-1"
    orchestrator.rc_project = "regional"
    orchestrator.mc_projects = ["mc01", "mc02"]
    orchestrator.target_monitor = FakeMonitor(events, failed_projects)
    orchestrator.collect_codebuild_logs = lambda: events.append(("collect_logs",))
    orchestrator._destroy_provisioner = lambda git: events.append(("destroy_provisioner",))
    return orchestrator


class TeardownTests(unittest.TestCase):
    def test_teardown_waits_for_all_mcs_before_starting_rc(self):
        events = []
        orchestrator = make_orchestrator(events)

        orchestrator._run_teardown(FakeGit(events))

        rc_start = events.index(("start", "regional", {"IS_DESTROY": "true"}))
        mc_waits = [
            index for index, event in enumerate(events)
            if event[0] == "wait" and event[1] in {"mc01", "mc02"}
        ]
        self.assertTrue(mc_waits)
        self.assertLess(max(mc_waits), rc_start)
        self.assertNotIn(("modify_config",), events)

    def test_teardown_does_not_start_rc_when_mc_fails(self):
        events = []
        orchestrator = make_orchestrator(events, failed_projects={"mc01"})

        with self.assertRaisesRegex(RuntimeError, "mc01"):
            orchestrator._run_teardown(FakeGit(events))

        self.assertNotIn(("start", "regional", {"IS_DESTROY": "true"}), events)
        self.assertNotIn(("destroy_provisioner",), events)
        self.assertIn(("collect_logs",), events)

    def test_fire_and_forget_still_pushes_delete_flags_without_starting_builds(self):
        events = []
        orchestrator = make_orchestrator(events)

        orchestrator._run_teardown(FakeGit(events), fire_and_forget=True)

        self.assertIn(("modify_config",), events)
        self.assertNotIn(("current_sha",), events)
        self.assertFalse(any(event[0] == "start" for event in events))


class ProvisionMetadataTests(unittest.TestCase):
    def test_writes_zoa_enablement_marker_next_to_saved_state(self):
        with TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "output" / "tf-outputs.json"

            write_provision_metadata(str(state_path), True)

            self.assertEqual((state_path.parent / "zoa-enabled").read_text(), "true\n")

    def test_writes_disabled_zoa_enablement_marker(self):
        with TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "output" / "tf-outputs.json"

            write_provision_metadata(str(state_path), False)

            self.assertEqual((state_path.parent / "zoa-enabled").read_text(), "false\n")


if __name__ == "__main__":
    unittest.main()
