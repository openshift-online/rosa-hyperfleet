"""Unit tests for render.py"""

import json
from pathlib import Path

import pytest
import yaml

from render import (
    cleanup_stale_files,
    create_applicationset_template,
    deep_merge,
    get_cluster_types,
    load_yaml,
    render_region_deployment_applicationsets,
    render_region_deployment_terraform,
    render_region_deployment_values,
    resolve_region_deployments,
    resolve_templates,
    save_yaml,
    validate_config_revisions,
    validate_region_deployment_uniqueness,
)


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
# validate_region_deployment_uniqueness
# =============================================================================


class TestValidateRegionDeploymentUniqueness:
    def test_passes_for_unique_combinations(self):
        rds = [
            {"environment": "staging", "region_deployment": "us-east-1"},
            {"environment": "staging", "region_deployment": "us-west-2"},
            {"environment": "production", "region_deployment": "us-east-1"},
        ]
        validate_region_deployment_uniqueness(rds)  # should not raise

    def test_raises_on_duplicate(self):
        rds = [
            {"environment": "staging", "region_deployment": "us-east-1"},
            {"environment": "staging", "region_deployment": "us-east-1"},
        ]
        with pytest.raises(ValueError, match="Duplicate"):
            validate_region_deployment_uniqueness(rds)

    def test_passes_for_empty_list(self):
        validate_region_deployment_uniqueness([])


# =============================================================================
# validate_config_revisions
# =============================================================================


class TestValidateConfigRevisions:
    def test_valid_short_hash(self):
        rds = [{"region_deployment": "us-east-1", "environment": "staging", "revision": "abc1234"}]
        validate_config_revisions(rds)  # should not raise

    def test_valid_full_hash(self):
        rds = [{"region_deployment": "us-east-1", "environment": "staging",
                "revision": "826fa76d08fc2ce87c863196e52d5a4fa9259a82"}]
        validate_config_revisions(rds)

    def test_main_is_allowed(self):
        rds = [{"region_deployment": "us-east-1", "environment": "staging", "revision": "main"}]
        validate_config_revisions(rds)

    def test_none_revision_is_allowed(self):
        rds = [{"region_deployment": "us-east-1", "environment": "staging", "revision": None}]
        validate_config_revisions(rds)

    def test_missing_revision_key_is_allowed(self):
        rds = [{"region_deployment": "us-east-1", "environment": "staging"}]
        validate_config_revisions(rds)

    def test_rejects_invalid_hash(self):
        rds = [{"region_deployment": "us-east-1", "environment": "staging", "revision": "not-a-hash!"}]
        with pytest.raises(ValueError, match="Invalid commit hash"):
            validate_config_revisions(rds)

    def test_rejects_too_short_hash(self):
        rds = [{"region_deployment": "us-east-1", "environment": "staging", "revision": "abc12"}]
        with pytest.raises(ValueError, match="Invalid commit hash"):
            validate_config_revisions(rds)

    def test_rejects_uppercase_hex(self):
        rds = [{"region_deployment": "us-east-1", "environment": "staging", "revision": "ABC1234"}]
        with pytest.raises(ValueError, match="Invalid commit hash"):
            validate_config_revisions(rds)


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
        assert deep_merge({"a": 1}, {"a": {"nested": True}}) == {"a": {"nested": True}}

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


# =============================================================================
# save_yaml
# =============================================================================


class TestSaveYaml:
    def test_creates_file_with_header_and_content(self, tmp_path):
        data = {"key": "value"}
        rd = {"region_deployment": "us-east-1", "environment": "staging"}
        output = tmp_path / "sub" / "output.yaml"

        save_yaml(data, output, "regional-cluster", rd)

        content = output.read_text()
        assert "GENERATED FILE - DO NOT EDIT MANUALLY" in content
        assert "regional-cluster" in content
        assert "us-east-1" in content
        assert "staging" in content
        assert "key: value" in content

    def test_creates_parent_directories(self, tmp_path):
        data = {"a": 1}
        rd = {"region_deployment": "r", "environment": "e"}
        output = tmp_path / "deep" / "nested" / "dir" / "file.yaml"

        save_yaml(data, output, "regional-cluster", rd)
        assert output.exists()

    def test_empty_data_produces_valid_yaml(self, tmp_path):
        rd = {"region_deployment": "r", "environment": "e"}
        output = tmp_path / "empty.yaml"

        save_yaml({}, output, "regional-cluster", rd)

        content = output.read_text()
        assert "GENERATED FILE" in content
        # The YAML body should be "{}\n" for an empty dict
        assert "{}" in content


# =============================================================================
# get_cluster_types
# =============================================================================


class TestGetClusterTypes:
    def test_finds_cluster_directories(self, tmp_path):
        (tmp_path / "regional-cluster").mkdir()
        (tmp_path / "management-cluster").mkdir()
        (tmp_path / "shared").mkdir()  # should be excluded
        (tmp_path / "some-file.txt").touch()  # should be excluded

        result = sorted(get_cluster_types(tmp_path))
        assert result == ["management-cluster", "regional-cluster"]

    def test_excludes_hidden_directories(self, tmp_path):
        (tmp_path / ".hidden-cluster").mkdir()
        (tmp_path / "regional-cluster").mkdir()

        result = get_cluster_types(tmp_path)
        assert result == ["regional-cluster"]

    def test_returns_empty_for_no_clusters(self, tmp_path):
        (tmp_path / "shared").mkdir()
        (tmp_path / "something-else").mkdir()

        assert get_cluster_types(tmp_path) == []


# =============================================================================
# resolve_region_deployments
# =============================================================================


class TestResolveRegionDeployments:
    def test_simple_region_deployment(self):
        config = {
            "defaults": {},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {
                            "account_id": "111111111111",
                            "management_clusters": {},
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        assert len(result) == 1
        rd = result[0]
        assert rd["environment"] == "staging"
        assert rd["region_deployment"] == "us-east-1"
        assert rd["aws_region"] == "us-east-1"
        assert rd["account_id"] == "111111111111"

    def test_deep_merge_inheritance(self):
        config = {
            "defaults": {
                "terraform_vars": {"app_code": "infra", "service_phase": "dev"},
            },
            "environments": {
                "staging": {
                    "terraform_vars": {"service_phase": "staging"},
                    "region_deployments": {
                        "us-east-1": {
                            "management_clusters": {},
                        }
                    },
                }
            },
        }
        result = resolve_region_deployments(config)
        rd = result[0]
        # service_phase should be overridden by env level
        assert rd["terraform_vars"]["app_code"] == "infra"
        assert rd["terraform_vars"]["service_phase"] == "staging"

    def test_rd_level_overrides_env_and_defaults(self):
        config = {
            "defaults": {"terraform_vars": {"key": "default"}},
            "environments": {
                "staging": {
                    "terraform_vars": {"key": "env"},
                    "region_deployments": {
                        "us-east-1": {
                            "terraform_vars": {"key": "rd"},
                            "management_clusters": {},
                        }
                    },
                }
            },
        }
        result = resolve_region_deployments(config)
        assert result[0]["terraform_vars"]["key"] == "rd"

    def test_jinja2_templates_resolved(self):
        config = {
            "defaults": {
                "terraform_vars": {
                    "region": "{{ aws_region }}",
                    "env": "{{ environment }}",
                },
            },
            "environments": {
                "prod": {
                    "region_deployments": {
                        "eu-west-1": {"management_clusters": {}}
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        rd = result[0]
        assert rd["terraform_vars"]["region"] == "eu-west-1"
        assert rd["terraform_vars"]["env"] == "prod"

    def test_management_clusters_converted_to_list(self):
        config = {
            "defaults": {},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {
                            "management_clusters": {
                                "mc01": {"account_id": "111"},
                                "mc02": {"account_id": "222"},
                            }
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        mcs = result[0]["management_clusters"]
        assert len(mcs) == 2
        ids = {mc["management_id"] for mc in mcs}
        assert ids == {"mc01", "mc02"}

    def test_management_cluster_default_account_id(self):
        config = {
            "defaults": {
                "management_cluster_account_id": "default-mc-account",
            },
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {
                            "management_clusters": {
                                "mc01": {},
                            }
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        mc = result[0]["management_clusters"][0]
        assert mc["account_id"] == "default-mc-account"

    def test_management_cluster_explicit_account_overrides_default(self):
        config = {
            "defaults": {
                "management_cluster_account_id": "default-mc-account",
            },
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {
                            "management_clusters": {
                                "mc01": {"account_id": "explicit-account"},
                            }
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        mc = result[0]["management_clusters"][0]
        assert mc["account_id"] == "explicit-account"

    def test_ci_prefix_applied_to_management_id(self):
        config = {
            "defaults": {},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {
                            "management_clusters": {"mc01": {}},
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config, ci_prefix="xg4y")
        mc = result[0]["management_clusters"][0]
        assert mc["management_id"] == "xg4y-mc01"

    def test_ci_prefix_applied_to_regional_id(self):
        config = {
            "defaults": {},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {"management_clusters": {}}
                    }
                }
            },
        }
        result = resolve_region_deployments(config, ci_prefix="xg4y")
        assert result[0]["regional_id"] == "xg4y-regional"

    def test_no_ci_prefix(self):
        config = {
            "defaults": {},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {"management_clusters": {"mc01": {}}}
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        assert result[0]["regional_id"] == "regional"
        assert result[0]["management_clusters"][0]["management_id"] == "mc01"

    def test_revision_inheritance(self):
        config = {
            "defaults": {"revision": "main"},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {
                            "revision": "abc1234",
                            "management_clusters": {},
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        assert result[0]["revision"] == "abc1234"

    def test_revision_falls_back_to_defaults(self):
        config = {
            "defaults": {"revision": "main"},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {"management_clusters": {}}
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        assert result[0]["revision"] == "main"

    def test_sector_support(self):
        config = {
            "defaults": {},
            "environments": {
                "prod": {
                    "sectors": {
                        "sector-a": {
                            "region_deployments": {
                                "us-east-1": {"management_clusters": {}}
                            }
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        assert len(result) == 1
        assert result[0]["sector"] == "sector-a"

    def test_implicit_sector_uses_env_name(self):
        config = {
            "defaults": {},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {"management_clusters": {}}
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        # Implicit default sector → sector set to env name
        assert result[0]["sector"] == "staging"

    def test_sector_terraform_vars_merge(self):
        config = {
            "defaults": {"terraform_vars": {"key": "default"}},
            "environments": {
                "prod": {
                    "sectors": {
                        "sector-a": {
                            "terraform_vars": {"key": "sector"},
                            "region_deployments": {
                                "us-east-1": {"management_clusters": {}}
                            },
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        assert result[0]["terraform_vars"]["key"] == "sector"

    def test_multiple_environments_and_regions(self):
        config = {
            "defaults": {},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {"management_clusters": {}},
                        "us-west-2": {"management_clusters": {}},
                    }
                },
                "prod": {
                    "region_deployments": {
                        "eu-west-1": {"management_clusters": {}}
                    }
                },
            },
        }
        result = resolve_region_deployments(config)
        assert len(result) == 3

    def test_empty_environments(self):
        config = {"defaults": {}, "environments": {}}
        assert resolve_region_deployments(config) == []

    def test_null_rd_config(self):
        """region_deployment value can be None/null in yaml."""
        config = {
            "defaults": {},
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": None,
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        assert len(result) == 1
        assert result[0]["management_clusters"] == []

    def test_account_id_template_resolution(self):
        config = {
            "defaults": {
                "account_id": "account-{{ environment }}-{{ aws_region }}",
            },
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {"management_clusters": {}}
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        assert result[0]["account_id"] == "account-staging-us-east-1"

    def test_management_cluster_template_with_cluster_prefix(self):
        config = {
            "defaults": {
                "management_cluster_account_id": "mc-{{ cluster_prefix }}-{{ aws_region }}",
            },
            "environments": {
                "staging": {
                    "region_deployments": {
                        "us-east-1": {
                            "management_clusters": {"mc01": {}},
                        }
                    }
                }
            },
        }
        result = resolve_region_deployments(config)
        mc = result[0]["management_clusters"][0]
        assert mc["account_id"] == "mc-mc01-us-east-1"

    def test_values_merge_chain(self):
        config = {
            "defaults": {
                "values": {
                    "regional-cluster": {"setting": "default"},
                    "global": {"shared": "from-defaults"},
                },
            },
            "environments": {
                "staging": {
                    "values": {
                        "regional-cluster": {"setting": "env-override"},
                    },
                    "region_deployments": {
                        "us-east-1": {"management_clusters": {}}
                    },
                }
            },
        }
        result = resolve_region_deployments(config)
        values = result[0]["values"]
        assert values["regional-cluster"]["setting"] == "env-override"
        assert values["global"]["shared"] == "from-defaults"


# =============================================================================
# create_applicationset_template
# =============================================================================


class TestCreateApplicationsetTemplate:
    def _write_base_applicationset(self, base_dir):
        appset_dir = base_dir / "applicationset"
        appset_dir.mkdir(parents=True)
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
        return base_dir

    def test_without_config_revision(self, tmp_path):
        base_dir = self._write_base_applicationset(tmp_path)
        result = create_applicationset_template(
            "regional-cluster", "staging", "us-east-1", None, base_dir
        )
        # Git generator revision should remain untouched
        git_gen = result["spec"]["generators"][0]["matrix"]["generators"][1]["git"]
        assert git_gen["revision"] == "HEAD"

    def test_with_config_revision(self, tmp_path):
        base_dir = self._write_base_applicationset(tmp_path)
        result = create_applicationset_template(
            "regional-cluster", "staging", "us-east-1", "abc1234def5", base_dir
        )
        # Git generator revision should be overridden
        git_gen = result["spec"]["generators"][0]["matrix"]["generators"][1]["git"]
        assert git_gen["revision"] == "abc1234def5"

        # First source (chart, no ref) should have targetRevision pinned
        sources = result["spec"]["template"]["spec"]["sources"]
        assert sources[0]["targetRevision"] == "abc1234def5"
        # Second source (ref: values) should keep original
        assert sources[1]["targetRevision"] == "HEAD"

    def test_raises_when_base_missing(self, tmp_path):
        with pytest.raises(ValueError, match="Base ApplicationSet not found"):
            create_applicationset_template(
                "regional-cluster", "staging", "us-east-1", None, tmp_path
            )


# =============================================================================
# render_region_deployment_values
# =============================================================================


class TestRenderRegionDeploymentValues:
    def test_creates_values_files(self, tmp_path):
        base_dir = tmp_path / "base"
        deploy_dir = tmp_path / "deploy"
        (base_dir / "regional-cluster").mkdir(parents=True)

        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "values": {
                "regional-cluster": {"setting": "value"},
            },
        }

        render_region_deployment_values(rd, ["regional-cluster"], base_dir, deploy_dir)

        output_file = deploy_dir / "staging" / "us-east-1" / "argocd" / "regional-cluster-values.yaml"
        assert output_file.exists()
        content = output_file.read_text()
        assert "setting: value" in content

    def test_global_values_merged_into_cluster_types(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "values": {
                "global": {"shared_key": "shared_val"},
                "regional-cluster": {"specific": "val"},
            },
        }

        render_region_deployment_values(rd, ["regional-cluster"], tmp_path, deploy_dir)

        output_file = deploy_dir / "staging" / "us-east-1" / "argocd" / "regional-cluster-values.yaml"
        content = yaml.safe_load(
            # Strip the header comment lines
            "\n".join(
                line for line in output_file.read_text().splitlines()
                if not line.startswith("#") and line.strip()
            )
        )
        assert content["shared_key"] == "shared_val"
        assert content["specific"] == "val"

    def test_empty_values_still_creates_file(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "values": {},
        }

        render_region_deployment_values(rd, ["regional-cluster"], tmp_path, deploy_dir)

        output_file = deploy_dir / "staging" / "us-east-1" / "argocd" / "regional-cluster-values.yaml"
        assert output_file.exists()


# =============================================================================
# render_region_deployment_applicationsets
# =============================================================================


class TestRenderRegionDeploymentApplicationsets:
    def _setup_base(self, tmp_path):
        appset_dir = tmp_path / "base" / "applicationset"
        appset_dir.mkdir(parents=True)
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
        return tmp_path / "base"

    def test_creates_applicationset_files(self, tmp_path):
        base_dir = self._setup_base(tmp_path)
        deploy_dir = tmp_path / "deploy"

        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "revision": None,
        }

        render_region_deployment_applicationsets(rd, ["regional-cluster"], deploy_dir, base_dir)

        output_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd"
            / "regional-cluster-manifests" / "applicationset.yaml"
        )
        assert output_file.exists()
        content = output_file.read_text()
        assert "GENERATED FILE" in content

    def test_pinned_revision_sets_commit_hash(self, tmp_path):
        base_dir = self._setup_base(tmp_path)
        deploy_dir = tmp_path / "deploy"

        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "revision": "abc1234def5678901234567890abcdef12345678",
        }

        render_region_deployment_applicationsets(rd, ["regional-cluster"], deploy_dir, base_dir)

        output_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd"
            / "regional-cluster-manifests" / "applicationset.yaml"
        )
        content = output_file.read_text()
        assert "abc1234d" in content  # truncated hash in header

    def test_main_revision_is_not_pinned(self, tmp_path):
        base_dir = self._setup_base(tmp_path)
        deploy_dir = tmp_path / "deploy"

        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "revision": "main",
        }

        render_region_deployment_applicationsets(rd, ["regional-cluster"], deploy_dir, base_dir)

        output_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd"
            / "regional-cluster-manifests" / "applicationset.yaml"
        )
        content = output_file.read_text()
        assert "metadata.annotations.git_revision" in content


# =============================================================================
# render_region_deployment_terraform
# =============================================================================


class TestRenderRegionDeploymentTerraform:
    def test_creates_regional_json(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "regional_id": "regional",
            "sector": "staging",
            "terraform_vars": {"app_code": "infra", "region": "us-east-1"},
            "management_clusters": [],
        }

        render_region_deployment_terraform(rd, deploy_dir)

        regional_file = deploy_dir / "staging" / "us-east-1" / "terraform" / "regional.json"
        assert regional_file.exists()
        data = json.loads(regional_file.read_text())
        assert data["app_code"] == "infra"
        assert data["regional_id"] == "regional"
        assert data["sector"] == "staging"
        assert data["_generated"].startswith("DO NOT EDIT")

    def test_creates_management_cluster_json(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "regional_id": "regional",
            "account_id": "999999999999",
            "sector": "staging",
            "terraform_vars": {"app_code": "infra"},
            "management_clusters": [
                {"management_id": "mc01", "account_id": "111111111111"},
            ],
        }

        render_region_deployment_terraform(rd, deploy_dir)

        mc_file = deploy_dir / "staging" / "us-east-1" / "terraform" / "management" / "mc01.json"
        assert mc_file.exists()
        data = json.loads(mc_file.read_text())
        assert data["management_id"] == "mc01"
        assert data["account_id"] == "111111111111"
        assert data["regional_aws_account_id"] == "999999999999"
        assert data["app_code"] == "infra"  # inherited from rd terraform_vars

    def test_mc_account_ids_added_to_regional(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "regional_id": "regional",
            "account_id": "999",
            "sector": "staging",
            "terraform_vars": {},
            "management_clusters": [
                {"management_id": "mc01", "account_id": "111"},
                {"management_id": "mc02", "account_id": "222"},
            ],
        }

        render_region_deployment_terraform(rd, deploy_dir)

        regional_file = deploy_dir / "staging" / "us-east-1" / "terraform" / "regional.json"
        data = json.loads(regional_file.read_text())
        assert data["management_cluster_account_ids"] == ["111", "222"]

    def test_no_mc_account_ids_when_empty(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "regional_id": "regional",
            "sector": "staging",
            "terraform_vars": {},
            "management_clusters": [],
        }

        render_region_deployment_terraform(rd, deploy_dir)

        regional_file = deploy_dir / "staging" / "us-east-1" / "terraform" / "regional.json"
        data = json.loads(regional_file.read_text())
        assert "management_cluster_account_ids" not in data

    def test_raises_on_missing_management_id(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "regional_id": "regional",
            "account_id": "999",
            "sector": "staging",
            "terraform_vars": {},
            "management_clusters": [{"account_id": "111"}],  # missing management_id
        }

        with pytest.raises(ValueError, match="missing 'management_id'"):
            render_region_deployment_terraform(rd, deploy_dir)

    def test_mc_extra_fields_preserved(self, tmp_path):
        """MC-specific fields like delete: true should appear in the output."""
        deploy_dir = tmp_path / "deploy"
        rd = {
            "environment": "staging",
            "region_deployment": "us-east-1",
            "regional_id": "regional",
            "account_id": "999",
            "sector": "staging",
            "terraform_vars": {},
            "management_clusters": [
                {"management_id": "mc01", "account_id": "111", "delete": True},
            ],
        }

        render_region_deployment_terraform(rd, deploy_dir)

        mc_file = deploy_dir / "staging" / "us-east-1" / "terraform" / "management" / "mc01.json"
        data = json.loads(mc_file.read_text())
        assert data["delete"] is True


# =============================================================================
# cleanup_stale_files
# =============================================================================


class TestCleanupStaleFiles:
    def test_removes_stale_region_deployment(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        # Create a directory for a region deployment that no longer exists
        stale_dir = deploy_dir / "staging" / "us-west-2" / "argocd"
        stale_dir.mkdir(parents=True)
        (stale_dir / "values.yaml").touch()

        # Only us-east-1 is valid
        rds = [{"environment": "staging", "region_deployment": "us-east-1", "management_clusters": []}]

        cleanup_stale_files(rds, deploy_dir)

        assert not (deploy_dir / "staging" / "us-west-2").exists()

    def test_keeps_valid_region_deployment(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        valid_dir = deploy_dir / "staging" / "us-east-1" / "argocd"
        valid_dir.mkdir(parents=True)
        (valid_dir / "values.yaml").touch()

        rds = [{"environment": "staging", "region_deployment": "us-east-1", "management_clusters": []}]

        cleanup_stale_files(rds, deploy_dir)

        assert (deploy_dir / "staging" / "us-east-1").exists()

    def test_removes_stale_management_cluster_files(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        mc_dir = deploy_dir / "staging" / "us-east-1" / "terraform" / "management"
        mc_dir.mkdir(parents=True)
        (mc_dir / "mc01.json").touch()
        (mc_dir / "mc02.json").touch()  # stale

        rds = [
            {
                "environment": "staging",
                "region_deployment": "us-east-1",
                "management_clusters": [{"management_id": "mc01"}],
            }
        ]

        cleanup_stale_files(rds, deploy_dir)

        assert (mc_dir / "mc01.json").exists()
        assert not (mc_dir / "mc02.json").exists()

    def test_no_op_when_deploy_dir_missing(self, tmp_path):
        deploy_dir = tmp_path / "nonexistent"
        cleanup_stale_files([], deploy_dir)  # should not raise

    def test_ignores_hidden_directories(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        hidden = deploy_dir / ".hidden"
        hidden.mkdir(parents=True)
        (hidden / "file.txt").touch()

        cleanup_stale_files([], deploy_dir)

        # Hidden dirs should be left untouched
        assert hidden.exists()
