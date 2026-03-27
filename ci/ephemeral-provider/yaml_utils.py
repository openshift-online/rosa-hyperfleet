"""YAML deep-merge utilities for provision overrides."""

import yaml


def deep_merge(base: dict, override: dict):
    """Recursively merge override into base (mutates base).

    - Dicts are merged recursively.
    - Lists of dicts are merged by matching on the 'name' key: if both the base
      and override item have a 'name' field, the matching base item is updated.
      Override items with no match are appended.
    - All other values (scalars, lists of non-dicts) are replaced by the override.
    """
    for key, value in override.items():
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            deep_merge(base[key], value)
        elif key in base and isinstance(base[key], list) and isinstance(value, list):
            _deep_merge_lists(base[key], value)
        else:
            base[key] = value


def _deep_merge_lists(base_list: list, override_list: list):
    """Merge two lists by matching dict items on 'name' key."""
    for override_item in override_list:
        if isinstance(override_item, dict) and "name" in override_item:
            match = next(
                (b for b in base_list if isinstance(b, dict) and b.get("name") == override_item["name"]),
                None,
            )
            if match:
                deep_merge(match, override_item)
            else:
                base_list.append(override_item)
        else:
            # Non-dict items or items without 'name': replace entire list
            base_list.clear()
            base_list.extend(override_list)
            return


def load_and_merge(target_path, override_path):
    """Load a target YAML file, deep-merge an override file into it, and write back."""
    with open(target_path) as f:
        base = yaml.safe_load(f) or {}
    with open(override_path) as f:
        override = yaml.safe_load(f) or {}

    if isinstance(base, dict) and isinstance(override, dict):
        deep_merge(base, override)
    else:
        base = override

    with open(target_path, "w") as f:
        yaml.dump(base, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
