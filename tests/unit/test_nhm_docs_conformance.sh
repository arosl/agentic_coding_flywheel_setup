#!/usr/bin/env bash
# The nhm forms of the lessons and the swarm scripts parse against nhm's
# real command tree; skipped without nhm ($NHM_BIN or PATH).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 -m unittest discover -s "$REPO_ROOT/tests/unit" -p 'test_nhm_docs_conformance.py' -v
