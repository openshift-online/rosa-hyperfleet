#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
#     "Jinja2>=3.1",
#     "pytest>=8.0",
#     "ruamel.yaml>=0.18",
# ]
# ///
"""Unit tests for render.py"""

import json
import shutil
from pathlib import Path

import pytest
import yaml

from render import (
    build_context,
    build_mc_list,
    check_docs,
    cleanup_stale_files,
    collect_leaf_paths,
    deep_merge,
    discover_environments,
    discover_regions,
    load_yaml,
    main,
    resolve_templates,
    scan_annotations,
    scan_template_variables,
    update_docs,
    write_output,
)

# Path to real templates and argocd config for integration-style tests
PROJECT_ROOT = Path(__file__).parent.parent
REAL_TEMPLATES_DIR = PROJECT_ROOT / "config" / "templates"
REAL_ARGOCD_CONFIG_DIR = PROJECT_ROOT / "argocd" / "config"


def _create_config_structure(
    tmp_path,
    global_defaults=None,
    environments=None,
):
    """Helper to create the new config directory structure.

    environments is a dict like:
        {
            "staging": {
                "defaults": { ... },      # config/<env>/defaults.yaml content
                "regions": {
                    "us-east-1": { ... },  # config/<env>/us-east-1.yaml content
                }
            }
        }
    """
    config_dir = tmp_path / "config"
    config_dir.mkdir(exist_ok=True)

    # Start with base required fields (mirrors real config/defaults.yaml)
    base_defaults = {
        "aws": {
            "account_id": "",
            "management_cluster_account_id": "000000000000",
        },
        "dns": {
            "domain": "",
        },
        "terraform_tags": {
            "app_code": "infra",
            "service_phase": "dev",
            "cost_center": "000",
        },
        "regional_cluster": {
            "enable_bastion": False,
            "node_instance_types": ["t3.medium", "t3a.medium"],
        },
        "management_cluster_defaults": {
            "enable_bastion": False,
            "node_instance_types": ["t3.medium", "t3a.medium"],
        },
    }

    # Merge test-provided defaults on top
    if global_defaults:
        final_defaults = deep_merge(base_defaults, global_defaults)
    else:
        final_defaults = base_defaults

    # Global defaults (always create)
    (config_dir / "defaults.yaml").write_text(yaml.dump(final_defaults))

    # Copy real templates
    templates_dest = config_dir / "templates"
    if REAL_TEMPLATES_DIR.exists():
        shutil.copytree(REAL_TEMPLATES_DIR, templates_dest, dirs_exist_ok=True)

    # Environment configs
    if environments:
        for env_name, env_data in environments.items():
            env_dir = config_dir / env_name
            env_dir.mkdir(exist_ok=True)

            env_defaults = env_data.get("defaults", {})
            (env_dir / "defaults.yaml").write_text(yaml.dump(env_defaults))

            for region_name, region_config in env_data.get("regions", {}).items():
                (env_dir / f"{region_name}.yaml").write_text(
                    yaml.dump(region_config)
                )

    return config_dir


def _create_argocd_config(tmp_path, cluster_types=None):
    """Helper to create argocd/config directory with cluster type dirs."""
    if cluster_types is None:
        cluster_types = ["regional-cluster", "management-cluster"]

    argocd_config_dir = tmp_path / "argocd" / "config"
    argocd_config_dir.mkdir(parents=True, exist_ok=True)

    for ct in cluster_types:
        (argocd_config_dir / ct).mkdir(exist_ok=True)

    # Copy base applicationset from real project
    appset_src = REAL_ARGOCD_CONFIG_DIR / "applicationset"
    appset_dest = argocd_config_dir / "applicationset"
    if appset_src.exists():
        shutil.copytree(appset_src, appset_dest, dirs_exist_ok=True)
    else:
        # Create a minimal base applicationset
        appset_dest.mkdir(exist_ok=True)
        _write_base_applicationset(appset_dest)

    return argocd_config_dir


def _write_base_applicationset(appset_dir):
    """Write a minimal base-applicationset.yaml for testing."""
    appset = {
        "spec": {
            "generators": [
                {
                    "matrix": {
                        "generators": [
                            {"clusters": {}},
                            {"git": {"revision": "HEAD"}},
                        ]
                    }
                }
            ],
            "template": {
                "spec": {
                    "sources": [
                        {"targetRevision": "HEAD", "path": "chart"},
                        {"targetRevision": "HEAD", "ref": "values"},
                    ]
                }
            },
        }
    }
    with open(appset_dir / "base-applicationset.yaml", "w") as f:
        yaml.dump(appset, f)


# =============================================================================
# load_yaml
# =============================================================================


class TestLoadYaml:
    def test_returns_parsed_content(self, tmp_path):
        f = tmp_path / "test.yaml"
        f.write_text("key: value\nnested:\n  a: 1\n")
        assert load_yaml(f) == {"key": "value", "nested": {"a": 1}}

    def test_returns_empty_dict_for_missing_file(self, tmp_path):
        assert load_yaml(tmp_path / "nonexistent.yaml") == {}

    def test_returns_empty_dict_for_empty_file(self, tmp_path):
        f = tmp_path / "empty.yaml"
        f.write_text("")
        assert load_yaml(f) == {}

    def test_returns_empty_dict_for_null_content(self, tmp_path):
        f = tmp_path / "null.yaml"
        f.write_text("---\n")
        assert load_yaml(f) == {}


# =============================================================================
# discover_environments
# =============================================================================


class TestDiscoverEnvironments:
    def test_finds_environments_with_defaults_yaml(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        staging = config_dir / "staging"
        staging.mkdir()
        (staging / "defaults.yaml").write_text("revision: main\n")
        prod = config_dir / "prod"
        prod.mkdir()
        (prod / "defaults.yaml").write_text("revision: main\n")

        result = discover_environments(config_dir)
        assert sorted(result) == ["prod", "staging"]

    def test_excludes_dirs_without_defaults_yaml(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        staging = config_dir / "staging"
        staging.mkdir()
        (staging / "defaults.yaml").write_text("revision: main\n")
        # This dir has no defaults.yaml, should be excluded
        (config_dir / "incomplete").mkdir()

        result = discover_environments(config_dir)
        assert result == ["staging"]

    def test_excludes_templates_directory(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        templates = config_dir / "templates"
        templates.mkdir()
        (templates / "defaults.yaml").write_text("something\n")

        result = discover_environments(config_dir)
        assert result == []

    def test_excludes_hidden_directories(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        hidden = config_dir / ".hidden"
        hidden.mkdir()
        (hidden / "defaults.yaml").write_text("revision: main\n")

        result = discover_environments(config_dir)
        assert result == []

    def test_returns_sorted(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        for name in ["zebra", "alpha", "middle"]:
            d = config_dir / name
            d.mkdir()
            (d / "defaults.yaml").write_text("{}\n")

        result = discover_environments(config_dir)
        assert result == ["alpha", "middle", "zebra"]

    def test_returns_empty_for_no_environments(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        result = discover_environments(config_dir)
        assert result == []


# =============================================================================
# discover_regions
# =============================================================================


class TestDiscoverRegions:
    def test_finds_region_yaml_files(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")
        (env_dir / "us-west-2.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert sorted(result) == ["us-east-1", "us-west-2"]

    def test_excludes_defaults_yaml(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == ["us-east-1"]

    def test_returns_empty_for_no_regions(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == []

    def test_returns_sorted(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "eu-west-1.yaml").write_text("{}\n")
        (env_dir / "ap-southeast-1.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == ["ap-southeast-1", "eu-west-1", "us-east-1"]


# =============================================================================
# deep_merge
# =============================================================================


class TestDeepMerge:
    def test_flat_merge(self):
        assert deep_merge({"a": 1}, {"b": 2}) == {"a": 1, "b": 2}

    def test_overlay_overrides_base(self):
        assert deep_merge({"a": 1}, {"a": 2}) == {"a": 2}

    def test_nested_merge(self):
        base = {"x": {"a": 1, "b": 2}}
        overlay = {"x": {"b": 3, "c": 4}}
        assert deep_merge(base, overlay) == {"x": {"a": 1, "b": 3, "c": 4}}

    def test_deeply_nested_merge(self):
        base = {"x": {"y": {"a": 1}}}
        overlay = {"x": {"y": {"b": 2}}}
        assert deep_merge(base, overlay) == {"x": {"y": {"a": 1, "b": 2}}}

    def test_overlay_replaces_non_dict_with_dict(self):
        assert deep_merge({"a": 1}, {"a": {"nested": True}}) == {
            "a": {"nested": True}
        }

    def test_overlay_replaces_dict_with_non_dict(self):
        assert deep_merge({"a": {"nested": True}}, {"a": "flat"}) == {"a": "flat"}

    def test_does_not_mutate_base(self):
        base = {"a": {"b": 1}}
        overlay = {"a": {"c": 2}}
        deep_merge(base, overlay)
        assert base == {"a": {"b": 1}}

    def test_empty_base(self):
        assert deep_merge({}, {"a": 1}) == {"a": 1}

    def test_empty_overlay(self):
        assert deep_merge({"a": 1}, {}) == {"a": 1}

    def test_both_empty(self):
        assert deep_merge({}, {}) == {}


# =============================================================================
# resolve_templates
# =============================================================================


class TestResolveTemplates:
    def test_simple_string_substitution(self):
        result = resolve_templates("hello {{ name }}", {"name": "world"})
        assert result == "hello world"

    def test_no_template_in_string(self):
        assert resolve_templates("plain text", {}) == "plain text"

    def test_dict_values_resolved(self):
        data = {"key": "{{ env }}-value", "static": "no-change"}
        result = resolve_templates(data, {"env": "prod"})
        assert result == {"key": "prod-value", "static": "no-change"}

    def test_list_values_resolved(self):
        data = ["{{ a }}", "{{ b }}"]
        result = resolve_templates(data, {"a": "x", "b": "y"})
        assert result == ["x", "y"]

    def test_nested_structures(self):
        data = {"outer": {"inner": "{{ val }}"}}
        result = resolve_templates(data, {"val": "resolved"})
        assert result == {"outer": {"inner": "resolved"}}

    def test_non_string_passthrough(self):
        assert resolve_templates(42, {}) == 42
        assert resolve_templates(True, {}) is True
        assert resolve_templates(None, {}) is None

    def test_mixed_list(self):
        data = ["{{ x }}", 42, {"k": "{{ x }}"}]
        result = resolve_templates(data, {"x": "val"})
        assert result == ["val", 42, {"k": "val"}]

    def test_asbool_filter_true(self):
        result = resolve_templates("{{ val | asbool }}", {"val": True})
        assert result is True

    def test_asbool_filter_false(self):
        result = resolve_templates("{{ val | asbool }}", {"val": False})
        assert result is False

    def test_asbool_filter_string_true(self):
        assert resolve_templates("{{ val | asbool }}", {"val": "true"}) is True
        assert resolve_templates("{{ val | asbool }}", {"val": "True"}) is True
        assert resolve_templates("{{ val | asbool }}", {"val": "TRUE"}) is True

    def test_asbool_filter_string_false(self):
        assert resolve_templates("{{ val | asbool }}", {"val": "false"}) is False
        assert resolve_templates("{{ val | asbool }}", {"val": "False"}) is False
        assert resolve_templates("{{ val | asbool }}", {"val": "0"}) is False

    def test_asbool_filter_numeric(self):
        assert resolve_templates("{{ val | asbool }}", {"val": 1}) is True
        assert resolve_templates("{{ val | asbool }}", {"val": 0}) is False

    def test_asbool_rejects_invalid_value(self):
        with pytest.raises(ValueError, match="asbool filter"):
            resolve_templates("{{ val | asbool }}", {"val": "anything"})

    def test_asbool_in_nested_dict(self):
        data = {"outer": {"enabled": "{{ flag | asbool }}"}}
        result = resolve_templates(data, {"flag": False})
        assert result == {"outer": {"enabled": False}}

    def test_no_coercion_without_asbool(self):
        result = resolve_templates("{{ val }}", {"val": True})
        assert result == "True"

    def test_plain_string_false_not_coerced(self):
        result = resolve_templates("false", {})
        assert result == "false"

    def test_undefined_variable_raises(self):
        with pytest.raises(ValueError, match="undefined"):
            resolve_templates("{{ regional_cluster.observe.nothere }}", {})

    def test_undefined_nested_with_default_ok(self):
        result = resolve_templates(
            "{{ regional_cluster.observe.nothere | default('fallback') }}", {}
        )
        assert result == "fallback"

    def test_undefined_in_dict_raises(self):
        data = {"key": "{{ missing.nested.path }}"}
        with pytest.raises(ValueError, match="undefined"):
            resolve_templates(data, {})


# =============================================================================
# write_output
# =============================================================================


class TestWriteOutput:
    def test_creates_file_with_content(self, tmp_path):
        output = tmp_path / "sub" / "output.txt"
        write_output("hello world", output)
        assert output.exists()
        assert output.read_text() == "hello world\n"

    def test_creates_parent_directories(self, tmp_path):
        output = tmp_path / "deep" / "nested" / "dir" / "file.txt"
        write_output("content", output)
        assert output.exists()

    def test_adds_trailing_newline(self, tmp_path):
        output = tmp_path / "file.txt"
        write_output("no newline", output)
        assert output.read_text().endswith("\n")

    def test_preserves_existing_trailing_newline(self, tmp_path):
        output = tmp_path / "file.txt"
        write_output("has newline\n", output)
        content = output.read_text()
        assert content == "has newline\n"
        assert not content.endswith("\n\n")


# =============================================================================
# build_context
# =============================================================================


class TestBuildContext:
    def test_injects_identity_variables(self):
        ctx = build_context({}, "staging", "us-east-1", "")
        assert ctx["environment"] == "staging"
        assert ctx["aws_region"] == "us-east-1"

    def test_eph_prefix_injected(self):
        ctx = build_context({}, "staging", "us-east-1", "xg4y")
        assert ctx["ci_prefix"] == "xg4y"

    def test_resolves_account_id_template(self):
        merged = {"aws": {"account_id": "account-{{ environment }}-{{ aws_region }}"}}
        ctx = build_context(merged, "staging", "us-east-1", "")
        assert ctx["account_id"] == "account-staging-us-east-1"

    def test_resolves_terraform_common_templates(self):
        merged = {"terraform_tags": {"region": "{{ aws_region }}"}}
        ctx = build_context(merged, "prod", "eu-west-1", "")
        assert ctx["terraform_tags"]["region"] == "eu-west-1"


# =============================================================================
# build_mc_list
# =============================================================================


class TestBuildMcList:
    def test_builds_mc_entries(self):
        merged = {"provision_mcs": {"mc01": {"account_id": "111"}}}
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert len(mc_list) == 1
        assert mc_list[0]["management_id"] == "mc01"
        assert mc_list[0]["account_id"] == "111"

    def test_eph_prefix_applied(self):
        merged = {"provision_mcs": {"mc01": {"account_id": "111"}}}
        ctx = build_context(merged, "staging", "us-east-1", "xg4y")
        mc_list = build_mc_list(ctx, merged, "xg4y")
        assert mc_list[0]["management_id"] == "xg4y-mc01"

    def test_default_account_id(self):
        merged = {
            "aws": {"management_cluster_account_id": "default-account"},
            "provision_mcs": {"mc01": {}},
        }
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "default-account"

    def test_explicit_account_overrides_default(self):
        merged = {
            "aws": {"management_cluster_account_id": "default-account"},
            "provision_mcs": {"mc01": {"account_id": "explicit-account"}},
        }
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "explicit-account"

    def test_cluster_prefix_template_resolution(self):
        merged = {
            "aws": {"management_cluster_account_id": "mc-{{ cluster_prefix }}-{{ aws_region }}"},
            "provision_mcs": {"mc01": {}},
        }
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "mc-mc01-us-east-1"


# =============================================================================
# cleanup_stale_files
# =============================================================================


class TestCleanupStaleFiles:
    def test_removes_stale_environment(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        stale_dir = deploy_dir / "old-env" / "us-east-1"
        stale_dir.mkdir(parents=True)
        (stale_dir / "file.txt").touch()

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert not (deploy_dir / "old-env").exists()

    def test_removes_stale_region(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        stale_dir = deploy_dir / "staging" / "us-west-2"
        stale_dir.mkdir(parents=True)
        (stale_dir / "file.txt").touch()
        valid_dir = deploy_dir / "staging" / "us-east-1"
        valid_dir.mkdir(parents=True)

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert not (deploy_dir / "staging" / "us-west-2").exists()
        assert (deploy_dir / "staging" / "us-east-1").exists()

    def test_keeps_valid_region(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        valid_dir = deploy_dir / "staging" / "us-east-1"
        valid_dir.mkdir(parents=True)
        (valid_dir / "file.txt").touch()

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert (deploy_dir / "staging" / "us-east-1").exists()

    def test_removes_stale_mc_input_directories(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        region_dir = deploy_dir / "staging" / "us-east-1"
        # Valid MC dir
        (region_dir / "pipeline-management-cluster-mc01-inputs").mkdir(parents=True)
        # Stale MC dir
        (region_dir / "pipeline-management-cluster-mc02-inputs").mkdir(parents=True)

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": {"mc01"}}},
            deploy_dir=deploy_dir,
        )

        assert (
            region_dir / "pipeline-management-cluster-mc01-inputs"
        ).exists()
        assert not (
            region_dir / "pipeline-management-cluster-mc02-inputs"
        ).exists()

    def test_removes_stale_mc_provisioner_files(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        prov_dir = deploy_dir / "staging" / "us-east-1" / "pipeline-provisioner-inputs"
        prov_dir.mkdir(parents=True)
        (prov_dir / "management-cluster-mc01.json").touch()
        (prov_dir / "management-cluster-mc02.json").touch()  # stale

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": {"mc01"}}},
            deploy_dir=deploy_dir,
        )

        assert (prov_dir / "management-cluster-mc01.json").exists()
        assert not (prov_dir / "management-cluster-mc02.json").exists()

    def test_no_op_when_deploy_dir_missing(self, tmp_path):
        deploy_dir = tmp_path / "nonexistent"
        cleanup_stale_files(
            valid_envs=set(),
            env_regions={},
            env_region_mcs={},
            deploy_dir=deploy_dir,
        )  # should not raise

    def test_ignores_hidden_directories(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        hidden = deploy_dir / ".hidden"
        hidden.mkdir(parents=True)
        (hidden / "file.txt").touch()

        cleanup_stale_files(
            valid_envs=set(),
            env_regions={},
            env_region_mcs={},
            deploy_dir=deploy_dir,
        )

        assert hidden.exists()


# =============================================================================
# Integration tests: config merge + output files
# =============================================================================


class TestConfigMergeAndRendering:
    """Tests that exercise the full merge chain (global -> env -> region)
    by creating config structures and verifying the merged output."""

    def test_deep_merge_inheritance(self, tmp_path):
        """Global defaults are merged with env defaults and region config."""
        global_defaults = {
            "terraform_common": {"app_code": "infra", "service_phase": "dev"},
        }
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults=global_defaults,
            environments={
                "staging": {
                    "defaults": {"terraform_common": {"service_phase": "staging"}},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        assert merged["terraform_common"]["app_code"] == "infra"
        assert merged["terraform_common"]["service_phase"] == "staging"

    def test_region_level_overrides_env_and_defaults(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"terraform_common": {"key": "default"}},
            environments={
                "staging": {
                    "defaults": {"terraform_common": {"key": "env"}},
                    "regions": {
                        "us-east-1": {
                            "terraform_common": {"key": "region"},
                            "provision_mcs": {},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        assert merged["terraform_common"]["key"] == "region"

    def test_jinja2_templates_resolved_in_terraform(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "terraform_tags": {
                    "region": "{{ aws_region }}",
                    "env": "{{ environment }}",
                },
            },
            environments={
                "prod": {
                    "defaults": {},
                    "regions": {
                        "eu-west-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "prod" / "defaults.yaml")
        rc = load_yaml(config_dir / "prod" / "eu-west-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        ctx = build_context(merged, "prod", "eu-west-1", "")
        assert ctx["terraform_tags"]["region"] == "eu-west-1"
        assert ctx["terraform_tags"]["env"] == "prod"

    def test_provision_mcs_in_region(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {"account_id": "111"},
                                "mc02": {"account_id": "222"},
                            },
                        },
                    },
                }
            },
        )

        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        mc_dict = rc.get("provision_mcs", {})
        assert len(mc_dict) == 2
        assert "mc01" in mc_dict
        assert "mc02" in mc_dict

    def test_management_cluster_default_account_id(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "default-mc-account"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "default-mc-account"

    def test_management_cluster_explicit_account_overrides_default(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "default-mc-account"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {"account_id": "explicit-account"},
                            },
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "explicit-account"

    def test_eph_prefix_applied_to_management_id(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "xg4y")
        mc_list, _ = build_mc_list(ctx, merged, "xg4y")
        assert len(mc_list) == 1
        assert mc_list[0]["management_id"] == "xg4y-mc01"

    def test_eph_prefix_stored_in_context(self):
        ctx = build_context({}, "staging", "us-east-1", "xg4y")
        assert ctx["ci_prefix"] == "xg4y"

    def test_empty_eph_prefix(self):
        ctx = build_context({}, "staging", "us-east-1", "")
        assert ctx["ci_prefix"] == ""

    def test_revision_inheritance(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "git": {"revision": "abc1234"},
                            "provision_mcs": {},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["git"]["revision"] == "abc1234"

    def test_revision_falls_back_to_defaults(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["git"]["revision"] == "main"

    def test_applications_merge_chain(self, tmp_path):
        """applications values merge through defaults -> env -> region."""
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "applications": {
                    "regional-cluster": {"setting": "default", "shared": "from-defaults"},
                },
            },
            environments={
                "staging": {
                    "defaults": {
                        "applications": {
                            "regional-cluster": {"setting": "env-override"},
                        },
                    },
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        apps = merged["applications"]
        assert apps["regional-cluster"]["setting"] == "env-override"
        assert apps["regional-cluster"]["shared"] == "from-defaults"

    def test_arbitrary_field_inherits_without_code_changes(self, tmp_path):
        """Any field inherits through the full merge chain."""
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"custom_field": "from-defaults", "only_in_defaults": True},
            environments={
                "staging": {
                    "defaults": {"custom_field": "from-env"},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["custom_field"] == "from-env"
        assert merged["only_in_defaults"] is True

    def test_account_id_template_resolution(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "account-{{ environment }}-{{ aws_region }}"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "")
        assert ctx["account_id"] == "account-staging-us-east-1"

    def test_management_cluster_template_with_cluster_prefix(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "mc-{{ cluster_prefix }}-{{ aws_region }}"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "mc-mc01-us-east-1"


# =============================================================================
# Integration tests: full main() run
# =============================================================================


class TestMainIntegration:
    """Tests that run main() end-to-end and verify deploy/ output files."""

    def _run_main(self, tmp_path, global_defaults, environments, eph_prefix=""):
        """Helper to run main() with a tmp_path-based project root."""
        import sys
        import render

        config_dir = _create_config_structure(
            tmp_path,
            global_defaults=global_defaults,
            environments=environments,
        )
        _create_argocd_config(tmp_path)

        deploy_dir = tmp_path / "deploy"

        # Patch sys.argv
        old_argv = sys.argv
        args = ["render.py", "--config-dir", str(config_dir)]
        if eph_prefix:
            args.extend(["--eph-prefix", eph_prefix])
        sys.argv = args

        # Patch the project_root derivation in main()
        old_file = render.__file__
        render.__file__ = str(tmp_path / "scripts" / "render.py")

        try:
            result = main()
        finally:
            sys.argv = old_argv
            render.__file__ = old_file

        assert result == 0, "main() should return 0 on success"
        return deploy_dir

    def test_region_definitions_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "staging" / "region-definitions.json"
        assert region_defs_file.exists()
        data = json.loads(region_defs_file.read_text())
        assert "us-east-1" in data
        entry = data["us-east-1"]
        assert entry["name"] == "staging"
        assert entry["environment"] == "staging"
        assert entry["aws_region"] == "us-east-1"

    def test_region_definitions_multiple_regions(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "prod": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                        "us-west-2": {"provision_mcs": {}},
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "prod" / "region-definitions.json"
        data = json.loads(region_defs_file.read_text())
        assert len(data) == 2
        assert "us-east-1" in data
        assert "us-west-2" in data

    def test_region_definitions_multiple_environments(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                },
                "prod": {
                    "defaults": {},
                    "regions": {
                        "eu-west-1": {"provision_mcs": {}},
                    },
                },
            },
        )

        assert (deploy_dir / "staging" / "region-definitions.json").exists()
        assert (deploy_dir / "prod" / "region-definitions.json").exists()

    def test_region_definitions_with_provision_mcs(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {},
                                "mc02": {},
                            },
                        },
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "staging" / "region-definitions.json"
        data = json.loads(region_defs_file.read_text())
        assert sorted(data["us-east-1"]["management_clusters"]) == ["mc01", "mc02"]

    def test_pipeline_provisioner_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"dns": {"domain": "test.example.com"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "terraform.json"
        )
        assert tf_file.exists()
        data = json.loads(tf_file.read_text())
        assert data["domain"] == "test.example.com"

    def test_pipeline_provisioner_regional_cluster_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"aws": {"account_id": "111111111111"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        rc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "regional-cluster.json"
        )
        assert rc_file.exists()
        data = json.loads(rc_file.read_text())
        assert data["region"] == "us-east-1"
        assert data["regional_id"] == "regional"
        assert data["account_id"] == "111111111111"

    def test_pipeline_provisioner_management_cluster_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999999999999",
                    "management_cluster_account_id": "111111111111",
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        mc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "management-cluster-mc01.json"
        )
        assert mc_file.exists()
        data = json.loads(mc_file.read_text())
        assert data["management_id"] == "mc01"
        assert data["account_id"] == "111111111111"
        assert data["region"] == "us-east-1"

    def test_pipeline_regional_cluster_inputs_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111111111111"},
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        assert tf_file.exists()
        data = json.loads(tf_file.read_text())
        assert data["app_code"] == "infra"
        assert data["regional_id"] == "regional"
        assert data["environment"] == "staging"
        assert data["region"] == "us-east-1"
        assert data["_generated"].startswith("DO NOT EDIT")

    def test_pipeline_management_cluster_inputs_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999999999999",
                    "management_cluster_account_id": "111111111111",
                },
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {},
                            },
                        },
                    },
                }
            },
        )

        mc_tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-management-cluster-mc01-inputs"
            / "terraform.json"
        )
        assert mc_tf_file.exists()
        data = json.loads(mc_tf_file.read_text())
        assert data["management_id"] == "mc01"
        assert data["account_id"] == "111111111111"
        assert data["regional_aws_account_id"] == "999999999999"
        assert data["app_code"] == "infra"

    def test_mc_account_ids_added_to_regional_terraform(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "999"},
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {"account_id": "111"},
                                "mc02": {"account_id": "222"},
                            },
                        },
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        assert sorted(data["management_cluster_account_ids"]) == ["111", "222"]

    def test_argocd_values_files(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "applications": {
                    "regional-cluster": {"setting": "value"},
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        values_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        )
        assert values_file.exists()
        content = values_file.read_text()
        assert "setting: value" in content
        assert "GENERATED FILE" in content

    def test_argocd_values_empty_creates_file(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        values_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        )
        assert values_file.exists()

    def test_argocd_bootstrap_applicationset(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        assert appset_file.exists()
        content = appset_file.read_text()
        assert "GENERATED FILE" in content

    def test_argocd_bootstrap_pinned_revision(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "git": {"revision": "abc1234def5678901234567890abcdef12345678"},
                            "provision_mcs": {},
                        },
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        content = appset_file.read_text()
        assert "abc1234d" in content  # truncated hash in header

    def test_argocd_bootstrap_main_revision_not_pinned(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        content = appset_file.read_text()
        assert "metadata.annotations.git_revision" in content

    def test_eph_prefix_in_regional_id(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111111111111"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
            eph_prefix="xg4y",
        )

        rc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "regional-cluster.json"
        )
        data = json.loads(rc_file.read_text())
        assert data["regional_id"] == "xg4y-regional"

    def test_eph_prefix_in_management_id(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999",
                    "management_cluster_account_id": "111",
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
            eph_prefix="xg4y",
        )

        mc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "management-cluster-xg4y-mc01.json"
        )
        assert mc_file.exists()
        data = json.loads(mc_file.read_text())
        assert data["management_id"] == "xg4y-mc01"

    def test_domain_in_provisioner_terraform(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "integration": {
                    "defaults": {"dns": {"domain": "int0.rosa.devshift.net"}},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "integration"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        assert data["domain"] == "int0.rosa.devshift.net"

    def test_instance_types_default_values(self, tmp_path):
        """Instance types should have default values from defaults.yaml"""
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111", "management_cluster_account_id": "222"},
                "regional_cluster": {
                    "node_instance_types": ["t3.medium", "t3a.medium"],
                },
                "management_cluster_defaults": {
                    "node_instance_types": ["t3.medium", "t3a.medium"],
                },
            },
            environments={
                "test": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {"mc01": {}}},
                    },
                }
            },
        )

        # Check MC terraform.json
        mc_file = (
            deploy_dir
            / "test"
            / "us-east-1"
            / "pipeline-management-cluster-mc01-inputs"
            / "terraform.json"
        )
        mc_data = json.loads(mc_file.read_text())
        assert mc_data["node_instance_types"] == ["t3.medium", "t3a.medium"]

        # Check RC terraform.json
        rc_file = (
            deploy_dir
            / "test"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        rc_data = json.loads(rc_file.read_text())
        assert rc_data["node_instance_types"] == ["t3.medium", "t3a.medium"]

    def test_instance_types_environment_override(self, tmp_path):
        """Instance types can be overridden at environment level"""
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111", "management_cluster_account_id": "222"},
                "regional_cluster": {
                    "node_instance_types": ["t3.medium"],
                },
                "management_cluster_defaults": {
                    "node_instance_types": ["t3.medium"],
                },
            },
            environments={
                "prod": {
                    "defaults": {
                        "regional_cluster": {
                            "node_instance_types": ["m5.xlarge", "m5a.xlarge"],
                        },
                        "management_cluster_defaults": {
                            "node_instance_types": ["m5.large", "m5a.large"],
                        },
                    },
                    "regions": {
                        "us-east-1": {"provision_mcs": {"mc01": {}}},
                    },
                }
            },
        )

        mc_file = (
            deploy_dir
            / "prod"
            / "us-east-1"
            / "pipeline-management-cluster-mc01-inputs"
            / "terraform.json"
        )
        mc_data = json.loads(mc_file.read_text())
        assert mc_data["node_instance_types"] == ["m5.large", "m5a.large"]

        rc_file = (
            deploy_dir
            / "prod"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        rc_data = json.loads(rc_file.read_text())
        assert rc_data["node_instance_types"] == ["m5.xlarge", "m5a.xlarge"]

    def test_instance_types_region_override(self, tmp_path):
        """Instance types can be overridden at region level"""
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111", "management_cluster_account_id": "222"},
                "regional_cluster": {
                    "node_instance_types": ["t3.medium"],
                },
                "management_cluster_defaults": {
                    "node_instance_types": ["t3.medium"],
                },
            },
            environments={
                "test": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "regional_cluster": {
                                "node_instance_types": ["c5.2xlarge"],
                            },
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        rc_file = (
            deploy_dir
            / "test"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        rc_data = json.loads(rc_file.read_text())
        assert rc_data["node_instance_types"] == ["c5.2xlarge"]

    def test_merged_config_yaml_output(self, tmp_path):
        """Verify _merged_config.yaml is written with merged configuration"""
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"terraform_tags": {"app_code": "test"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {"us-east-1": {"provision_mcs": {}}},
                }
            },
        )

        config_file = deploy_dir / "staging" / "us-east-1" / "_merged_config.yaml"
        assert config_file.exists()
        data = yaml.safe_load(config_file.read_text())
        assert data["terraform_tags"]["app_code"] == "test"


# =============================================================================
# Documentation system tests
# =============================================================================


class TestScanAnnotations:
    def test_parses_doc_and_used_by(self):
        content = "# @doc dns.domain The domain\n# @used-by dns.domain template.j2\n"
        result = scan_annotations(content)
        assert "dns.domain" in result
        assert result["dns.domain"]["doc"] == "The domain"
        assert result["dns.domain"]["used_by"] == ["template.j2"]

    def test_multiple_used_by(self):
        content = (
            "# @doc tf.app Application code.\n"
            "# @used-by tf.app a.j2\n"
            "# @used-by tf.app b.j2\n"
        )
        result = scan_annotations(content)
        assert result["tf.app"]["used_by"] == ["a.j2", "b.j2"]

    def test_context_sentinel(self):
        content = "# @doc aws.id Account ID.\n# @used-by aws.id _context\n"
        result = scan_annotations(content)
        assert result["aws.id"]["used_by"] == ["_context"]

    def test_indented_annotations(self):
        content = "  # @doc dns.domain The domain\n  # @used-by dns.domain template.j2\n"
        result = scan_annotations(content)
        assert "dns.domain" in result
        assert result["dns.domain"]["used_by"] == ["template.j2"]

    def test_empty_content(self):
        assert scan_annotations("") == {}

    def test_ignores_non_annotation_comments(self):
        content = "# This is a regular comment\nkey: value\n"
        assert scan_annotations(content) == {}


class TestScanTemplateVariables:
    def test_finds_expression_variables(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.json.j2").write_text('{{ dns.domain }}')
        result = scan_template_variables(tpl_dir)
        assert "dns.domain" in result
        assert result["dns.domain"] == ["test.json.j2"]

    def test_finds_if_variables(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.j2").write_text("{% if delete %}yes{% endif %}")
        result = scan_template_variables(tpl_dir)
        assert "delete" in result

    def test_ignores_builtins(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.j2").write_text("{{ loop.index }}")
        assert "loop.index" not in scan_template_variables(tpl_dir)

    def test_subdirectory_templates(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        sub = tpl_dir / "sub"
        sub.mkdir(parents=True)
        (sub / "test.j2").write_text("{{ dns.domain }}")
        result = scan_template_variables(tpl_dir)
        assert result["dns.domain"] == ["sub/test.j2"]


class TestCollectLeafPaths:
    def test_flat_dict(self):
        assert collect_leaf_paths({"a": 1, "b": 2}) == {"a", "b"}

    def test_nested_dict(self):
        assert collect_leaf_paths({"a": {"b": 1}}) == {"a.b"}

    def test_deeply_nested(self):
        assert collect_leaf_paths({"a": {"b": {"c": 1}}}) == {"a.b.c"}

    def test_empty_dict_is_leaf(self):
        assert collect_leaf_paths({"a": {}}) == {"a"}

    def test_mixed(self):
        result = collect_leaf_paths({"a": 1, "b": {"c": 2, "d": 3}})
        assert result == {"a", "b.c", "b.d"}


class TestCheckDocs:
    def _setup(self, tmp_path, defaults_content, templates=None):
        config = tmp_path / "config"
        config.mkdir()
        tpl = config / "templates"
        tpl.mkdir()
        (config / "defaults.yaml").write_text(defaults_content)
        if templates:
            for path, content in templates.items():
                full = tpl / path
                full.parent.mkdir(parents=True, exist_ok=True)
                full.write_text(content)
        return config, tpl

    def test_passes_when_all_documented(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc dns.domain The domain\n# @used-by dns.domain test.j2\ndns:\n  domain: ''\n",
            {"test.j2": "{{ dns.domain }}"},
        )
        assert check_docs(config, tpl) == 0

    def test_fails_undocumented_leaf(self, tmp_path):
        config, tpl = self._setup(tmp_path, "undocumented: value\n")
        assert check_docs(config, tpl) == 1

    def test_fails_missing_used_by(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc my.key desc\nmy:\n  key: val\n",
        )
        assert check_docs(config, tpl) == 1

    def test_fails_bad_template_ref(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc my.key desc\n# @used-by my.key nonexistent.j2\nmy:\n  key: val\n",
        )
        assert check_docs(config, tpl) == 1

    def test_fails_wrong_consumer(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc my.key desc\n# @used-by my.key test.j2\nmy:\n  key: val\n",
            {"test.j2": "{{ other_var }}"},
        )
        assert check_docs(config, tpl) == 1

    def test_fails_undocumented_template_var(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "{}\n",
            {"test.j2": "{{ undocumented.var }}"},
        )
        assert check_docs(config, tpl) == 1

    def test_fails_unused_leaf(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc my.key desc\n# @used-by my.key test.j2\nmy:\n  key: val\n",
            {"test.j2": "{{ dns.domain }}"},
        )
        assert check_docs(config, tpl) == 1

    def test_context_skips_template_check(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc git.rev Revision.\n# @used-by git.rev _context\ngit:\n  rev: main\n",
        )
        assert check_docs(config, tpl) == 0

    def test_context_vars_not_flagged(self, tmp_path):
        """Template vars in CONTEXT_VARS (e.g. environment) don't need @doc."""
        config, tpl = self._setup(
            tmp_path,
            "{}\n",
            {"test.j2": "{{ environment }}"},
        )
        assert check_docs(config, tpl) == 0

    def test_ancestor_doc_covers_leaf(self, tmp_path):
        """A @doc on a parent key covers child leaves."""
        config, tpl = self._setup(
            tmp_path,
            "# @doc tf desc\n# @used-by tf test.j2\ntf:\n  a: 1\n  b: 2\n",
            {"test.j2": "{{ tf.a }} {{ tf.b }}"},
        )
        assert check_docs(config, tpl) == 0

    def test_real_config(self):
        """Verify the actual project config passes the check."""
        config_dir = PROJECT_ROOT / "config"
        templates_dir = config_dir / "templates"
        assert check_docs(config_dir, templates_dir) == 0


class TestUpdateDocs:
    def test_regenerates_used_by(self, tmp_path):
        config = tmp_path / "config"
        config.mkdir()
        tpl = config / "templates"
        tpl.mkdir()
        (tpl / "test.j2").write_text("{{ dns.domain }}")
        (config / "defaults.yaml").write_text(
            "# @doc dns.domain The domain\n# @used-by dns.domain wrong.j2\ndns:\n  domain: ''\n"
        )
        assert update_docs(config, tpl) == 0
        content = (config / "defaults.yaml").read_text()
        assert "# @used-by dns.domain test.j2" in content
        assert "wrong.j2" not in content

    def test_preserves_context_entries(self, tmp_path):
        config = tmp_path / "config"
        config.mkdir()
        tpl = config / "templates"
        tpl.mkdir()
        (config / "defaults.yaml").write_text(
            "# @doc git.rev Revision\n# @used-by git.rev _context\ngit:\n  rev: main\n"
        )
        assert update_docs(config, tpl) == 0
        content = (config / "defaults.yaml").read_text()
        assert "# @used-by git.rev _context" in content

    def test_preserves_doc_descriptions(self, tmp_path):
        config = tmp_path / "config"
        config.mkdir()
        tpl = config / "templates"
        tpl.mkdir()
        (tpl / "test.j2").write_text("{{ dns.domain }}")
        (config / "defaults.yaml").write_text(
            "# @doc dns.domain My custom description\n# @used-by dns.domain old.j2\ndns:\n  domain: ''\n"
        )
        update_docs(config, tpl)
        content = (config / "defaults.yaml").read_text()
        assert "My custom description" in content


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
