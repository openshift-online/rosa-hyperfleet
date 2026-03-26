#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
# ]
# ///
"""
Validates that all Terraform modules use standard provider versions.

This script ensures consistency across all Terraform configurations by checking
that provider versions in versions.tf files match the canonical versions defined
in terraform/provider-versions.yaml.

Exit codes:
  0 - All provider versions match the standard
  1 - Version mismatches found or errors occurred
"""

import re
import sys
from pathlib import Path
import yaml

# ANSI colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
NC = '\033[0m'  # No Color


def load_standard_versions(versions_file: Path) -> dict:
    """Load standard provider versions from YAML."""
    with open(versions_file) as f:
        return yaml.safe_load(f)


def extract_provider_version(versions_tf_content: str, provider_name: str) -> str | None:
    """
    Extract provider version from versions.tf content.

    Matches patterns like:
      aws = {
        source  = "hashicorp/aws"
        version = ">= 6.0"
      }

    Returns the version string (e.g., ">= 6.0") or None if not found.
    """
    # Match provider block
    pattern = rf'{provider_name}\s*=\s*{{[^}}]*version\s*=\s*"([^"]+)"'
    match = re.search(pattern, versions_tf_content, re.DOTALL)
    if match:
        return match.group(1)
    return None


def extract_required_providers(versions_tf_content: str) -> set[str]:
    """
    Extract all provider names declared in a required_providers block.

    Returns a set of provider names found in the module's versions.tf.
    """
    block_match = re.search(
        r'required_providers\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}',
        versions_tf_content,
        re.DOTALL,
    )
    if not block_match:
        return set()
    block = block_match.group(1)
    return set(re.findall(r'^\s*(\w+)\s*=\s*\{', block, re.MULTILINE))


def extract_terraform_required_version(versions_tf_content: str) -> str | None:
    """
    Extract the required_version constraint from a versions.tf terraform block.

    Returns the version string or None if not declared.
    """
    match = re.search(r'required_version\s*=\s*"([^"]+)"', versions_tf_content)
    if match:
        return match.group(1)
    return None


def validate_module(versions_file: Path, standard: dict) -> tuple[bool, list[str]]:
    """
    Validate a single Terraform module's provider versions.

    Checks:
      - Provider versions match the canonical exact versions (no ranges allowed)
      - No undeclared providers (providers in module not in standard)
      - Terraform required_version matches canonical version

    Returns:
      (is_valid, errors) - tuple of validation result and list of error messages
    """
    with open(versions_file) as f:
        content = f.read()

    errors = []
    standard_providers = {
        (str(k) if k is not None else 'null'): v
        for k, v in standard['providers'].items()
    }

    # Check versions declared in the module against the standard (exact match required)
    for provider_name, provider_info in standard_providers.items():
        expected_version = provider_info['version']
        actual_version = extract_provider_version(content, provider_name)

        if actual_version:
            if actual_version.strip() != expected_version:
                errors.append(
                    f"  {provider_name:8} expected exact version '{expected_version}', "
                    f"got '{actual_version}'"
                )

    # Detect providers declared in the module but missing from the standard registry
    module_providers = extract_required_providers(content)
    for provider_name in sorted(module_providers):
        if provider_name not in standard_providers:
            errors.append(
                f"  {provider_name:8} is not in provider-versions.yaml — "
                f"add it to the canonical registry before using it"
            )

    # Enforce canonical Terraform core version
    canonical_tf_version = standard.get('terraform_version')
    if canonical_tf_version:
        actual_tf_version = extract_terraform_required_version(content)
        if actual_tf_version is None:
            errors.append(
                f"  terraform  required_version is not declared "
                f"(expected exact '{canonical_tf_version}')"
            )
        elif actual_tf_version.strip() != canonical_tf_version:
            errors.append(
                f"  terraform  required_version expected exact '{canonical_tf_version}', "
                f"got '{actual_tf_version}'"
            )

    return len(errors) == 0, errors


def main():
    repo_root = Path(__file__).parent.parent
    versions_config = repo_root / "terraform/provider-versions.yaml"

    if not versions_config.exists():
        print(f"{RED}ERROR: {versions_config} not found{NC}")
        return 1

    print("🔍 Validating Terraform provider versions...")
    print(f"📋 Standard: {versions_config.relative_to(repo_root)}")
    print()

    standard = load_standard_versions(versions_config)

    print("Expected versions:")
    for provider, info in standard['providers'].items():
        # Handle case where provider name is None (YAML null keyword)
        provider_name = str(provider) if provider is not None else 'null'
        if info is None or 'version' not in info:
            print(f"{RED}ERROR: Invalid provider config for '{provider_name}'{NC}")
            print("  Provider must have 'version' and 'source' keys")
            return 1
        print(f"  {provider_name:8} {info['version']}")
    if 'terraform_version' in standard:
        print(f"  {'terraform':8} {standard['terraform_version']}")
    print()

    # Find all versions.tf files (excluding .terraform/ directories with downloaded modules)
    versions_files = [
        f for f in repo_root.glob("terraform/**/versions.tf")
        if '.terraform' not in f.parts
    ]

    total_errors = 0
    failed_modules = []

    for versions_file in versions_files:
        module_path = versions_file.parent.relative_to(repo_root)
        valid, errors = validate_module(versions_file, standard)

        if not valid:
            print(f"{RED}❌ {module_path}{NC}")
            for error in errors:
                print(error)
            print()
            total_errors += len(errors)
            failed_modules.append(str(module_path))

    print("=" * 60)
    print("📊 Summary:")
    print(f"   Checked: {len(versions_files)} modules")

    if total_errors == 0:
        print(f"{GREEN}✅ All modules use standard provider versions{NC}")
        return 0
    else:
        print(f"{RED}❌ Found {total_errors} version mismatch(es) in {len(failed_modules)} module(s){NC}")
        print()
        print("To fix, update versions.tf files to use exact versions:")
        print(f'  version = "{next(iter(standard["providers"].values()))["version"]}"  # NOT ">= X.Y"')
        print()
        print("Or update terraform/provider-versions.yaml if you intend to upgrade.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
