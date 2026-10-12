#!/usr/bin/env bash
# tests/vm/lib/mock_anthropic.py, the rehearsal's mock model APIs: no real
# account, network or agent is used.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 -m unittest discover -s "$REPO_ROOT/tests/unit" -p 'test_mock_anthropic.py' -v
