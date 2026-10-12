#!/usr/bin/env bash
# tests/fixtures/nhm against what upstream's swarm scripts assert; no nhm,
# herdr or agent is run.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 -m unittest discover -s "$REPO_ROOT/tests/unit" -p 'test_nhm_caller_fixtures.py' -v
