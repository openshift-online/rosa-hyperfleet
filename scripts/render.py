#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
#     "Jinja2>=3.1",
# ]
# ///
"""
Generic Values Renderer

This script renders configuration values by:
1. Reading config.yaml to get the list of region deployments and their configurations
2. For each region deployment and cluster type, loading defaults from existing values files
3. Merging region deployment-specific overrides with defaults
4. Outputting merged values files to deploy/{environment}/{region_deployment}/argocd/{clustertype}-values.yaml
5. Generating terraform pipeline configs to deploy/{environment}/{region_deployment}/terraform/
"""

import argparse
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List

import yaml
from jinja2 import Environment


def load_yaml(file_path: Path) -> Dict[str, Any]:
    """Load and parse a YAML file.

    Args:
        file_path: Path to the YAML file

    Returns:
        Parsed YAML content as a dictionary
    """
    if not file_path.exists():
        return {}

    with open(file_path, "r") as f:
        return yaml.safe_load(f) or {}


def load_config(config_path: Path) -> Dict[str, Any]:
    """Load configuration from a single YAML file or a config directory.

    Auto-detects file vs directory:
    - File: loads it directly via load_yaml() (backward compatible)
    - Directory: loads defaults.yaml + each environments/*.yaml, assembles into
      {"defaults": {...}, "environments": {"<stem>": {...}}}

    Args:
        config_path: Path to a YAML file or a config directory

    Returns:
        Parsed configuration dictionary

    Raises:
        FileNotFoundError: If config_path doesn't exist or defaults.yaml is missing
        ValueError: If no environment files are found in directory mode
    """
    if not config_path.exists():
        raise FileNotFoundError(f"Config path not found: {config_path}")

    if config_path.is_file():
        return load_yaml(config_path)

    # Directory mode
    defaults_file = config_path / "defaults.config.yaml"
    if not defaults_file.exists():
        raise FileNotFoundError(
            f"defaults.config.yaml not found in config directory: {config_path}"
        )

    defaults = load_yaml(defaults_file)

    env_dir = config_path / "environments"
    env_files = sorted(env_dir.glob("*.config.yaml")) if env_dir.is_dir() else []
    if not env_files:
        raise ValueError(
            f"No environment files found in {env_dir}. "
            f"Expected one or more .yaml files in the environments/ subdirectory."
        )

    environments = {}
    for env_file in env_files:
        # Strip .config.yaml → env name (e.g. brian.config.yaml → brian)
        env_name = env_file.name.removesuffix(".config.yaml")
        environments[env_name] = load_yaml(env_file)

    return {"defaults": defaults, "environments": environments}


def validate_region_deployment_uniqueness(region_deployments):
    """Ensure environment + region_deployment combinations are unique across region deployments.

    Args:
        region_deployments: List of region deployment configurations

    Raises:
        ValueError: If duplicate environment + region_deployment combinations are found
    """
    seen_combinations = set()
    for rd in region_deployments:
        combination = (rd.get("environment"), rd.get("region_deployment"))
        if combination in seen_combinations:
            raise ValueError(
                f"Duplicate environment + region_deployment combination: {combination}"
            )
        seen_combinations.add(combination)


def validate_config_revisions(region_deployments):
    """Validate that specified config revisions are valid git commit hashes.

    Args:
        region_deployments: List of region deployment configurations

    Raises:
        ValueError: If a specified config revision is not a valid git commit hash format
    """
    import re

    # Git commit hash pattern (7-40 hex characters)
    commit_hash_pattern = re.compile(r"^[a-f0-9]{7,40}$")

    for rd in region_deployments:
        region_deployment = rd.get("region_deployment", "unknown")
        environment = rd.get("environment", "unknown")
        revision = rd.get("revision")

        # Only validate non-default revisions (branch names like "main" are not commit hashes)
        if revision and revision != "main":
            if not commit_hash_pattern.match(revision):
                raise ValueError(
                    f"Invalid commit hash for region deployment {region_deployment} ({environment}): "
                    f"'{revision}'. "
                    f"Expected 7-40 character hexadecimal string."
                )


def save_yaml(
    data: Dict[str, Any], file_path: Path, cluster_type: str, rd: Dict[str, Any]
) -> None:
    """Save a dictionary as a YAML file with proper headers.

    Args:
        data: Dictionary to save
        file_path: Path where to save the YAML file
        cluster_type: Type of cluster (management-cluster, regional-cluster, etc.)
        rd: Region deployment configuration
    """
    file_path.parent.mkdir(parents=True, exist_ok=True)

    # Generate header
    region_deployment = rd["region_deployment"]
    environment = rd["environment"]

    header = f"""# GENERATED FILE - DO NOT EDIT MANUALLY
#
# This file is automatically generated by the render script.
# To make changes:
# - For default changes: Edit values.yaml files in argocd/config/{cluster_type}/*/values.yaml or argocd/config/shared/*/values.yaml
# - For region deployment-specific changes: Edit config.yaml
# - Then run: scripts/render.py
#
# Cluster Type: {cluster_type}
# Region Deployment: {region_deployment} ({environment})
# Generated: {Path(__file__).name}
#

"""

    with open(file_path, "w") as f:
        f.write(header)
        yaml.dump(
            data,
            f,
            default_flow_style=False,
            sort_keys=False,
            allow_unicode=True,
            width=float("inf"),
        )


def deep_merge(base: Dict[str, Any], overlay: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively merge two dictionaries.

    Args:
        base: Base dictionary
        overlay: Dictionary to merge into base

    Returns:
        Merged dictionary
    """
    result = base.copy()

    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value

    return result


def resolve_templates(value: Any, context: Dict[str, Any]) -> Any:
    """Recursively resolve Jinja2 template placeholders in all string values.

    Args:
        value: Value to process (string, dict, list, or other)
        context: Dictionary of template variables (e.g. aws_region, environment)

    Returns:
        Value with all template placeholders resolved
    """
    if isinstance(value, str):
        return Environment().from_string(value).render(context)
    elif isinstance(value, dict):
        return {k: resolve_templates(v, context) for k, v in value.items()}
    elif isinstance(value, list):
        return [resolve_templates(item, context) for item in value]
    return value


def resolve_region_deployments(
    config: Dict[str, Any], ci_prefix: str = ""
) -> List[Dict[str, Any]]:
    """Resolve region deployments by walking the nested config hierarchy.

    Walks environments → [sectors →] region_deployments, deep-merging inheritable
    fields (terraform_vars, values) through the chain:
    defaults → environment → sector → region_deployment (most-specific wins).

    Environments may place region_deployments directly (implicit default sector)
    or use explicit ``sectors:`` for multi-sector setups.

    Scalar fields (revision, bootstrap_pipeline_revision) use simple override
    (most-specific non-None wins).

    Management clusters are converted from dict form to list form with auto-derived
    management_id = mc_key (e.g., "mc01").  If an MC entry omits account_id, the
    defaults.management_cluster_account_id template is applied with
    ``cluster_prefix`` (the MC dict key) available in the Jinja2 context.

    All string values are then template-processed using region deployment fields
    as context.

    Args:
        config: Full parsed config.yaml

    Returns:
        List of fully resolved region deployment configurations
    """
    defaults = config.get("defaults", {})
    environments = config.get("environments", {})

    resolved = []
    for env_name, env_config in environments.items():
        env_config = env_config or {}

        # Support both explicit sectors and flattened region_deployments
        if "sectors" in env_config:
            sectors = env_config["sectors"] or {}
        elif "region_deployments" in env_config:
            # Implicit default sector
            sectors = {
                "default": {"region_deployments": env_config["region_deployments"]}
            }
        else:
            sectors = {}

        for sector_name, sector_config in sectors.items():
            sector_config = sector_config or {}
            for rd_name, rd_config in (
                sector_config.get("region_deployments") or {}
            ).items():
                rd_config = rd_config or {}
                rd = {}

                # Set identity fields
                rd["name"] = rd_name
                rd["aws_region"] = rd_name
                rd["region"] = rd_name
                rd["region_deployment"] = rd_name
                rd["environment"] = env_name
                rd["sector"] = sector_name if sector_name != "default" else env_name

                # Compute deterministic regional_id
                rd["regional_id"] = f"{ci_prefix}-regional" if ci_prefix else "regional"

                # Resolve account_id: rd → sector → env → defaults (first non-None wins)
                raw_account_id = (
                    rd_config.get("account_id")
                    or sector_config.get("account_id")
                    or env_config.get("account_id")
                    or defaults.get("account_id", "")
                )
                rd["account_id"] = resolve_templates(raw_account_id, rd)

                # Deep merge terraform_vars: defaults → env → sector → rd
                tf_vars = deep_merge(
                    defaults.get("terraform_vars", {}),
                    env_config.get("terraform_vars", {}),
                )
                tf_vars = deep_merge(tf_vars, sector_config.get("terraform_vars", {}))
                tf_vars = deep_merge(tf_vars, rd_config.get("terraform_vars", {}))
                rd["terraform_vars"] = tf_vars

                # Deep merge values: defaults → env → sector → rd
                values = deep_merge(
                    defaults.get("values", {}), env_config.get("values", {})
                )
                values = deep_merge(values, sector_config.get("values", {}))
                values = deep_merge(values, rd_config.get("values", {}))
                rd["values"] = values

                # Convert management_clusters dict → list with auto-derived management_id
                mc_dict = rd_config.get("management_clusters") or {}
                default_mc_account_id = defaults.get("management_cluster_account_id")
                mc_list = []
                for mc_key, mc_val in mc_dict.items():
                    mc_entry = dict(mc_val) if mc_val else {}
                    mc_entry["management_id"] = (
                        f"{ci_prefix}-{mc_key}" if ci_prefix else mc_key
                    )
                    # Apply default MC account_id if not specified
                    if "account_id" not in mc_entry and default_mc_account_id:
                        mc_entry["account_id"] = default_mc_account_id
                    # Template-process with augmented context (cluster_prefix)
                    mc_context = dict(rd)
                    mc_context["cluster_prefix"] = mc_key
                    mc_entry = resolve_templates(mc_entry, mc_context)
                    mc_list.append(mc_entry)
                rd["management_clusters"] = mc_list

                # Lifecycle flags (control teardown behavior — require explicit boolean True)
                if rd_config.get('delete') is True:
                    rd['delete'] = True
                if rd_config.get('delete_pipeline') is True:
                    rd['delete_pipeline'] = True

                # Inherit revision (scalar override: most-specific non-None wins)
                rd["revision"] = (
                    rd_config.get("revision")
                    or sector_config.get("revision")
                    or env_config.get("revision")
                    or defaults.get("revision")
                )

                # Template-process values and terraform_vars
                rd["values"] = resolve_templates(rd["values"], rd)
                rd["terraform_vars"] = resolve_templates(rd["terraform_vars"], rd)

                resolved.append(rd)

    return resolved


def get_cluster_types(base_dir: Path) -> List[str]:
    """Discover cluster types by looking at directories.

    Args:
        base_dir: Base directory to scan

    Returns:
        List of cluster type names
    """
    cluster_types = []
    for item in base_dir.iterdir():
        if (
            item.is_dir()
            and not item.name.startswith(".")
            and item.name.endswith("cluster")
        ):
            cluster_types.append(item.name)
    return cluster_types


def create_applicationset_template(
    cluster_type: str,
    environment: str,
    region_deployment: str,
    config_revision: str = None,
    base_dir: Path = None,
) -> Dict[str, Any]:
    """Create ApplicationSet YAML template with specific commit hash or default revision.

    Args:
        cluster_type: Type of cluster (management-cluster, regional-cluster, etc.)
        environment: Environment name
        region_deployment: Region alias identifier
        config_revision: Optional commit hash for versioned deployments
        base_dir: Base directory path (for loading base ApplicationSet)

    Returns:
        ApplicationSet dictionary
    """
    # Always load the base ApplicationSet as the starting point
    base_applicationset_path = base_dir / "applicationset" / "base-applicationset.yaml"
    if not base_applicationset_path.exists():
        raise ValueError(f"Base ApplicationSet not found: {base_applicationset_path}")

    applicationset = load_yaml(base_applicationset_path)

    # If config_revision is specified, override the git revision to use the specific commit hash
    if config_revision:
        # Find the git generator in the matrix and update its revision
        generators = applicationset["spec"]["generators"][0]["matrix"]["generators"]
        for generator in generators:
            if "git" in generator:
                # Override revision with specific commit hash
                generator["git"]["revision"] = config_revision
                break

        # Update only the first source (chart + values.yaml) to use the specific commit hash
        # The second source (ref: values) should keep using metadata.annotations.git_revision
        sources = applicationset["spec"]["template"]["spec"]["sources"]
        for i, source in enumerate(sources):
            if "targetRevision" in source and "ref" not in source:
                # This is the chart source (first source) - update to use config_revision
                source["targetRevision"] = config_revision

    return applicationset


def render_region_deployment_applicationsets(
    rd: Dict[str, Any], cluster_types: List[str], deploy_dir: Path, base_dir: Path
) -> None:
    """Generate ApplicationSet files for each cluster type.

    Args:
        rd: Region deployment configuration
        cluster_types: List of cluster types to render
        deploy_dir: Path to the deploy output directory
        base_dir: Base directory path (for loading base ApplicationSet)
    """
    environment = rd["environment"]
    region_deployment = rd["region_deployment"]
    revision = rd.get("revision")
    # A non-default revision pins all cluster types to that commit hash
    pinned_revision = revision if (revision and revision != "main") else None

    # Create output directory
    output_dir = deploy_dir / environment / region_deployment / "argocd"
    output_dir.mkdir(parents=True, exist_ok=True)

    # Process each cluster type
    for cluster_type in cluster_types:
        config_revision = pinned_revision

        applicationset_data = create_applicationset_template(
            cluster_type, environment, region_deployment, config_revision, base_dir
        )

        # Create cluster-type manifests directory (simplified structure)
        manifests_dir = output_dir / f"{cluster_type}-manifests"
        manifests_dir.mkdir(parents=True, exist_ok=True)

        # ApplicationSet goes in the manifests directory
        output_file = manifests_dir / "applicationset.yaml"
        revision_info = (
            config_revision[:8]
            if config_revision
            else "metadata.annotations.git_revision"
        )

        with open(output_file, "w") as f:
            f.write(f"""# GENERATED FILE - DO NOT EDIT MANUALLY
#
# This file is automatically generated by the render script.
# To make changes:
# - Edit config.yaml for config_revision references
# - Then run: scripts/render.py
#
# Cluster Type: {cluster_type}
# Region Deployment: {region_deployment} ({environment})
# Config Revision: {revision_info}
# Generated: {Path(__file__).name}
#

""")
            yaml.dump(
                applicationset_data,
                f,
                default_flow_style=False,
                sort_keys=False,
                allow_unicode=True,
                width=float("inf"),
            )

        print(
            f"  [OK] deploy/{environment}/{region_deployment}/argocd/{cluster_type}-manifests/applicationset.yaml (Config Revision: {revision_info})"
        )


def render_region_deployment_values(
    rd: Dict[str, Any], cluster_types: List[str], base_dir: Path, deploy_dir: Path
) -> None:
    """Render values files for all cluster types for a region deployment.

    Args:
        rd: Region deployment configuration
        cluster_types: List of cluster types to render
        base_dir: Base directory containing cluster type directories
        deploy_dir: Path to the deploy output directory
    """
    environment = rd["environment"]
    region_deployment = rd["region_deployment"]

    print(f"Processing region deployment: {region_deployment} ({environment})")

    # Create output directory
    output_dir = deploy_dir / environment / region_deployment / "argocd"
    output_dir.mkdir(parents=True, exist_ok=True)

    # Process each cluster type
    for cluster_type in cluster_types:
        # Get region deployment-specific values for this cluster type
        rd_cluster_values = rd.get("values", {}).get(cluster_type, {})

        # Get top-level values from the region deployment (not cluster-specific)
        rd_top_level_values = {
            k: v
            for k, v in rd.get("values", {}).items()
            if k not in cluster_types and k != "global"
        }

        # Get global values that apply to this cluster type
        global_values = rd.get("values", {}).get("global", {})

        # Merge only the overrides: global_values <- rd_top_level <- rd_cluster_values
        # Do NOT include helm chart defaults - those stay in the charts
        override_values = deep_merge(global_values.copy(), rd_top_level_values)
        override_values = deep_merge(override_values, rd_cluster_values)

        # Always save values file (even if empty) as it's referenced in ApplicationSet
        output_file = output_dir / f"{cluster_type}-values.yaml"
        save_yaml(override_values, output_file, cluster_type, rd)
        if override_values:
            print(
                f"  [OK] deploy/{environment}/{region_deployment}/argocd/{cluster_type}-values.yaml"
            )
        else:
            print(
                f"  [OK] deploy/{environment}/{region_deployment}/argocd/{cluster_type}-values.yaml (empty - no overrides)"
            )


def render_region_deployment_terraform(rd: Dict[str, Any], deploy_dir: Path) -> None:
    """Generate terraform pipeline config files for a region deployment.

    Creates:
    - deploy/<env>/<region_deployment>/terraform/regional.json
    - deploy/<env>/<region_deployment>/terraform/management/<management_id>.json

    Args:
        rd: Region deployment configuration
        deploy_dir: Path to the deploy output directory
    """
    environment = rd["environment"]
    region_deployment = rd["region_deployment"]

    terraform_dir = deploy_dir / environment / region_deployment / "terraform"
    terraform_dir.mkdir(parents=True, exist_ok=True)

    # Generate regional.json from region deployment terraform_vars (already merged with sector)
    regional_file = terraform_dir / "regional.json"
    regional_data = rd.get("terraform_vars", {}).copy()

    # Add deterministic regional_id for resource naming
    regional_data["regional_id"] = rd["regional_id"]

    # Add sector for tagging
    regional_data["sector"] = rd.get("sector", environment)

    # Lifecycle flags (consistent with MC pattern — top-level, not in terraform_vars)
    if rd.get('delete') is True:
        regional_data['delete'] = True
    if rd.get('delete_pipeline') is True:
        regional_data['delete_pipeline'] = True

    # Extract all management cluster account IDs for cross-account access configuration
    management_clusters = rd.get("management_clusters", [])
    mc_account_ids = [
        mc.get("account_id") for mc in management_clusters if mc.get("account_id")
    ]

    # Add management cluster account IDs to regional config if any exist
    if mc_account_ids:
        regional_data["management_cluster_account_ids"] = mc_account_ids

    # Add metadata at the beginning
    regional_data_with_metadata = {
        "_generated": "DO NOT EDIT - Generated by scripts/render.py from config.yaml",
        **regional_data,
    }

    with open(regional_file, "w") as f:
        json.dump(regional_data_with_metadata, f, indent=2)
        f.write("\n")  # Add trailing newline

    print(f"  [OK] deploy/{environment}/{region_deployment}/terraform/regional.json")

    # Generate management cluster configs
    management_clusters = rd.get("management_clusters", [])
    if management_clusters:
        management_dir = terraform_dir / "management"
        management_dir.mkdir(parents=True, exist_ok=True)

        for mc in management_clusters:
            # Validate management_id is present and non-empty
            management_id = mc.get("management_id")
            if not management_id:
                raise ValueError(
                    f"Management cluster missing 'management_id' in region deployment {environment}/{region_deployment}. "
                    f"Management cluster config: {mc}"
                )

            mc_file = management_dir / f"{management_id}.json"

            # Build MC terraform_vars by merging region deployment terraform_vars with MC-specific overrides
            rd_tf_vars = rd.get("terraform_vars", {}).copy()
            rd_tf_vars["sector"] = rd.get("sector", environment)

            # MC-specific overrides (these override region deployment values)
            # This allows additional fields to be captured such as delete: true
            mc_overrides = mc.copy()

            # Then apply standard overrides that we always set
            mc_overrides.update(
                {
                    "account_id": mc.get("account_id"),
                    "alias": management_id,
                    "management_id": management_id,
                    "regional_aws_account_id": rd.get("account_id"),
                }
            )

            mc_data = deep_merge(rd_tf_vars, mc_overrides)

            # Add metadata at the beginning
            mc_data_with_metadata = {
                "_generated": "DO NOT EDIT - Generated by scripts/render.py from config.yaml",
                **mc_data,
            }

            with open(mc_file, "w") as f:
                json.dump(mc_data_with_metadata, f, indent=2)
                f.write("\n")  # Add trailing newline

            print(
                f"  [OK] deploy/{environment}/{region_deployment}/terraform/management/{management_id}.json"
            )


def render_environment_accounts(
    region_deployments: List[Dict[str, Any]], deploy_dir: Path
) -> None:
    """Generate accounts.json for each environment.

    Groups region deployments by environment and writes a single
    deploy/<environment>/terraform/accounts.json containing a
    region_definitions map with one entry per region.

    Args:
        region_deployments: List of resolved region deployment configurations
        deploy_dir: Path to the deploy output directory
    """
    # Group region deployments by environment
    envs: Dict[str, Dict[str, Any]] = {}
    for rd in region_deployments:
        env = rd["environment"]
        aws_region = rd["aws_region"]
        if env not in envs:
            envs[env] = {}
        envs[env][aws_region] = {
            "name": env,
            "environment": env,
            "aws_region": aws_region,
        }

    for env, region_definitions in envs.items():
        env_dir = deploy_dir / env
        env_dir.mkdir(parents=True, exist_ok=True)

        accounts_data = {
            "_generated": "DO NOT EDIT - Generated by scripts/render.py",
            "region_definitions": region_definitions,
        }

        accounts_file = env_dir / "accounts.json"
        with open(accounts_file, "w") as f:
            json.dump(accounts_data, f, indent=2)
            f.write("\n")

        print(f"  [OK] deploy/{env}/accounts.json")


def cleanup_stale_files(
    region_deployments: List[Dict[str, Any]], deploy_dir: Path
) -> None:
    """Remove stale files from deploy directory that no longer exist in config.yaml.

    Args:
        region_deployments: List of resolved region deployment configurations
        deploy_dir: Path to the deploy output directory
    """
    if not deploy_dir.exists():
        return

    # Build a set of valid region deployment paths (environment/region_deployment)
    valid_rd_paths = {
        (rd["environment"], rd["region_deployment"]) for rd in region_deployments
    }

    # Build a mapping of region deployment -> set of management cluster IDs
    rd_mc_map = {}
    for rd in region_deployments:
        key = (rd["environment"], rd["region_deployment"])
        # Only include non-empty management IDs
        mc_ids = {
            mc["management_id"]
            for mc in rd.get("management_clusters", [])
            if mc.get("management_id")
        }
        rd_mc_map[key] = mc_ids

    removed_count = 0

    # Scan deploy directory for environments
    for env_dir in deploy_dir.iterdir():
        if not env_dir.is_dir() or env_dir.name.startswith("."):
            continue

        environment = env_dir.name

        # Scan for region directories within this environment
        for region_dir in env_dir.iterdir():
            if not region_dir.is_dir() or region_dir.name.startswith("."):
                continue

            region_deployment = region_dir.name
            rd_key = (environment, region_deployment)

            # If this region deployment no longer exists in config.yaml, remove the entire directory
            if rd_key not in valid_rd_paths:
                print(
                    f"  [CLEANUP] Removing stale region deployment: deploy/{environment}/{region_deployment}/"
                )
                shutil.rmtree(region_dir)
                removed_count += 1
                continue

            # Check for stale management cluster files
            mc_dir = region_dir / "terraform" / "management"
            if mc_dir.exists():
                valid_mc_ids = rd_mc_map.get(rd_key, set())

                for mc_file in mc_dir.glob("*.json"):
                    # Extract management_id from filename (e.g., mc01.json -> mc01)
                    management_id = mc_file.stem

                    if management_id not in valid_mc_ids:
                        print(
                            f"  [CLEANUP] Removing stale MC: deploy/{environment}/{region_deployment}/terraform/management/{mc_file.name}"
                        )
                        mc_file.unlink()
                        removed_count += 1

    if removed_count > 0:
        print()


def resolve_config_path(config_path: str = None, project_root: Path = None) -> Path:
    """Resolve the config path (file or directory).

    When no explicit path is given, auto-detects:
    1. config/defaults.yaml exists → return config/ directory
    2. Otherwise → return config.yaml (legacy fallback)

    Args:
        config_path: Optional explicit path to config file or directory
        project_root: Project root directory (used for auto-detection)

    Returns:
        Resolved Path to the config file or directory
    """
    if config_path:
        return Path(config_path)

    config_dir = project_root / "config"
    if (config_dir / "defaults.config.yaml").exists():
        return config_dir

    return project_root / "config.yaml"


def main() -> int:
    """Main entry point for the script.

    Returns:
        Exit code (0 for success, 1 for error)
    """
    # Parse CLI arguments
    parser = argparse.ArgumentParser(
        description="Render configuration values from config.yaml"
    )
    parser.add_argument(
        "--ci-prefix",
        default=os.environ.get("CI_PREFIX", ""),
        help='Optional prefix for resource names in CI/test environments (e.g., "xg4y")',
    )
    parser.add_argument(
        "--config-dir",
        default=None,
        help="Path to config file or directory (default: auto-detect config/ or config.yaml)",
    )
    args = parser.parse_args()
    ci_prefix = args.ci_prefix

    # Determine script location and project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent

    config_path = resolve_config_path(args.config_dir, project_root)
    base_dir = project_root / "argocd" / "config"
    deploy_dir = project_root / "deploy"

    if ci_prefix:
        print(f"CI prefix: {ci_prefix}")

    # Load config
    try:
        config = load_config(config_path)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    # Resolve region deployments from config (merge sector defaults + template processing)
    region_deployments = resolve_region_deployments(config, ci_prefix=ci_prefix)
    if not region_deployments:
        print("Error: No region deployments found in config.yaml", file=sys.stderr)
        return 1

    # Validate environment + region_deployment uniqueness
    try:
        validate_region_deployment_uniqueness(region_deployments)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    # Validate config revision references
    try:
        validate_config_revisions(region_deployments)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    # Discover cluster types
    cluster_types = get_cluster_types(base_dir)
    if not cluster_types:
        print("Error: No cluster types found", file=sys.stderr)
        return 1

    print(f"Found {len(region_deployments)} region deployment(s)")
    print(f"Found cluster types: {', '.join(cluster_types)}")
    print()

    # Clean up stale files before rendering
    cleanup_stale_files(region_deployments, deploy_dir)

    # Process each region deployment
    for rd in region_deployments:
        environment = rd.get("environment")
        region_deployment = rd.get("region_deployment")

        if not (environment and region_deployment):
            print(
                f"Error: config.yaml entry must include environment and region_deployment: {rd}",
                file=sys.stderr,
            )
            return 1

        render_region_deployment_values(rd, cluster_types, base_dir, deploy_dir)
        render_region_deployment_applicationsets(
            rd, cluster_types, deploy_dir, base_dir
        )
        render_region_deployment_terraform(rd, deploy_dir)
        print()

    # Generate per-environment accounts.json
    render_environment_accounts(region_deployments, deploy_dir)

    print("[OK] Rendering complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
