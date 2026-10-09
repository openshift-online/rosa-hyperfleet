#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = ["boto3", "PyYAML>=6.0", "Jinja2>=3.1", "pytest>=8.0", "ruamel.yaml>=0.18"]
# ///
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
import yaml

import render

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ci" / "ephemeral-provider"))
import orchestrator
from aws import AWSCredentials


@pytest.mark.parametrize("operation", ["provision", "resync"])
@pytest.mark.parametrize("account,role,build_id", [
    ("599476212575", "OrganizationAccountAccessRole", ""),
    ("720644165472", "OrganizationAccountAccessRole", "ci-test"),
    ("987654321098", "rosa-hyperfleet-account-admin", ""),
])
def test_ephemeral_operator_config(tmp_path, monkeypatch, operation, account, role, build_id):
    monkeypatch.setenv("BUILD_ID", build_id)
    shutil.copytree(PROJECT_ROOT / "config" / "ephemeral", tmp_path / "config" / "ephemeral")
    region_file = tmp_path / "config" / "ephemeral" / "us-east-1.yaml"
    region_file.write_text(yaml.safe_dump({
        "provision_mcs": {"mc01": {}},
        "aws": {"account_id": "111111111111", "child_admin_role_name": role},
    }))

    def session(profile_name):
        identity = {"Account": account if profile_name == "rrp-rc" else "210987654321"}
        return SimpleNamespace(client=lambda service: SimpleNamespace(get_caller_identity=lambda: identity))

    monkeypatch.setattr(orchestrator.boto3, "Session", session)
    env = orchestrator.EphemeralEnvOrchestrator("test/repo", "test", "unused", "us-east-1", "authz-test")
    credentials = AWSCredentials()
    monkeypatch.setattr(env, "_setup_aws", lambda: setattr(env, "aws", credentials))
    monkeypatch.setattr(orchestrator, "PipelineMonitor", lambda session: None)
    monkeypatch.setattr(env, "_bootstrap_pipeline_provisioner", Mock())
    monkeypatch.setattr(env, "_wait_for_provision", Mock())
    bundles = []

    def render_config(message, **kwargs):
        merged = render.load_yaml(PROJECT_ROOT / "config" / "defaults.yaml")
        merged = render.deep_merge(merged, render.load_yaml(tmp_path / "config" / "ephemeral" / "defaults.yaml"))
        merged = render.deep_merge(merged, render.load_yaml(region_file))
        ctx = render.build_context(merged, "ephemeral", "us-east-1", "authz-test")
        ctx["management_clusters"] = render.build_mc_list(ctx, merged, "authz-test")
        applications = render.resolve_templates(ctx["applications"], ctx)
        ctx.update(cluster_type="regional-cluster", application_values=applications["regional-cluster"])
        values = yaml.safe_load(render.render_template(PROJECT_ROOT / "config" / "templates" / "argocd-values.yaml.j2", ctx))
        assert set(values["platformApi"]["authz"]) == {"config"}
        bundles.append(yaml.safe_load(values["platformApi"]["authz"]["config"]))

    git = SimpleNamespace(
        work_dir=tmp_path, create_eph_branch=Mock(), resync_eph_branch=Mock(), render_and_push=render_config,
    )
    monkeypatch.setattr(orchestrator, "GitManager", lambda *args, **kwargs: git)
    getattr(env, operation)()

    assert len(bundles) == 1
    bundle = bundles[0]
    assert bundle["formatVersion"] == 1
    assert bundle["registeredAccounts"].count(account) == 1
    assert "111111111111" not in bundle["registeredAccounts"]
    assert bundle["serviceOperatorPolicies"] == [{
        "id": "provision-management-clusters", "ownerAccountID": account,
        "content": 'permit(principal, action in [HyperFleet::Action::"CreateManagementCluster", HyperFleet::Action::"ListManagementClusters", HyperFleet::Action::"DescribeManagementCluster"], resource);\n',
    }]
    assert bundle["serviceOperatorAttachments"] == [{
        "id": "regional-provisioner", "policyID": "provision-management-clusters",
        "principalARN": f"arn:aws:iam::{account}:role/{role}", "scope": "regional", "region": "us-east-1",
    }]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
