#!/bin/bash
# CI entrypoint for unit tests.
set -euo pipefail

export UV_NO_CACHE=1

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== Running render.py unit tests ==="
uv run scripts/test_render.py

echo ""
echo "=== Running ephemeral authorization tests ==="
uv run scripts/test_ephemeral_authz.py

echo ""
echo "=== Running platform registration tests ==="
uv run --with pytest python -m pytest -q scripts/test_platform_registration.py

echo ""
echo "=== Running promtool rule tests ==="
./ci/promtool-test.sh
