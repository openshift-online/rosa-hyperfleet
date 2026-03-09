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


def normalize_version(version: str) -> str:
    """
    Remove constraint operators from version string.

    Examples:
      ">= 6.0" -> "6.0"
      "~> 6.0.0" -> "6.0.0"
      "= 6.0.0" -> "6.0.0"
      "6.0.0" -> "6.0.0"
    """
    return re.sub(r'^[=~>< ]+', '', version).strip()


def validate_module(versions_file: Path, standard: dict) -> tuple[bool, list[str]]:
    """
    Validate a single Terraform module's provider versions.

    Returns:
      (is_valid, errors) - tuple of validation result and list of error messages
    """
    with open(versions_file) as f:
        content = f.read()

    errors = []

    for provider_key, provider_info in standard['providers'].items():
        # Convert None to 'null' string (YAML null keyword handling)
        provider_name = str(provider_key) if provider_key is not None else 'null'
        expected_version = provider_info['version']
        actual_version = extract_provider_version(content, provider_name)

        if actual_version:
            actual_clean = normalize_version(actual_version)

            if actual_clean != expected_version:
                errors.append(
                    f"  {provider_name:8} expected '{expected_version}', "
                    f"got '{actual_version}'"
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
            print(f"  Provider must have 'version' and 'source' keys")
            return 1
        print(f"  {provider_name:8} {info['version']}")
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
        print(f'  version = "{list(standard["providers"].values())[0]["version"]}"  # NOT ">= X.Y"')
        print()
        print("Or update terraform/provider-versions.yaml if you intend to upgrade.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
