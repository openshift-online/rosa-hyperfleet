#!/bin/bash
# CI entrypoint for unit tests.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== Running render.py unit tests ==="
uv run scripts/test_render.py
