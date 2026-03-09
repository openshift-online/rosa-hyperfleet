#!/usr/bin/env python3
"""
Generate Terraform configuration for initializing provider cache.

Reads provider-versions.yaml and generates a minimal Terraform config
that downloads all required providers into the plugin cache.
"""

import yaml
import sys
from pathlib import Path


def main():
    versions_file = Path('/tmp/provider-versions.yaml')
    output_file = Path('/tmp/provider-init.tf')

    if not versions_file.exists():
        print(f"ERROR: {versions_file} not found", file=sys.stderr)
        sys.exit(1)

    # Load provider versions
    with open(versions_file) as f:
        config = yaml.safe_load(f)

    # Generate Terraform configuration
    tf_config = 'terraform {\n  required_providers {\n'

    for name, info in config['providers'].items():
        # Handle YAML null keyword - convert None to 'null' string
        provider_name = str(name) if name is not None else 'null'
        tf_config += f'    {provider_name} = {{\n'
        tf_config += f'      source  = "{info["source"]}"\n'
        tf_config += f'      version = "{info["version"]}"\n'
        tf_config += '    }\n'

    tf_config += '  }\n}\n'

    # Write to output file
    with open(output_file, 'w') as f:
        f.write(tf_config)

    print(f"✅ Generated {output_file}")
    print("\nTerraform configuration:")
    print(tf_config)


if __name__ == '__main__':
    main()
