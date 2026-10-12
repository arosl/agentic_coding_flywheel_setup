# nhm caller fixtures

nhm's robot output in ntm's shapes, for the callers that switch from ntm to
nhm (acfs-9hkh.27: the swarm scripts' nhm branch). A fake nhm in their tests
prints these files.

- The field names and types are nhm's: `internal/robot/{types,spawn,send}.go`
  in arosl/nhm at f3ca4fb, which project nhm's results onto ntm's types.
- `upstream_checks.py` holds what upstream's swarm Python asserts on that
  output, copied from upstream ACFS at b1819865.
- `request.json` is the launch and packet request the fixtures answer: the
  session `demo`, a claude and a codex agent, and one packet to slot `1.2`.

| File | nhm form |
|---|---|
| `robot_spawn.json`, `robot_spawn_dry_run.json` | `nhm --robot-spawn=demo …` with and without `--dry-run` |
| `robot_send_dry_run.json`, `robot_send.json` | `nhm --robot-send=demo --panes=1.2 --type=codex --msg-file=- …` with and without `--dry-run` |
| `robot_send_receipt.json` | `nhm --robot-send-receipt=packet-demo-0001` after a submitted send |
| `robot_send_receipt_unconfirmed.json` | the same after a possibly submitted send (`OPERATION_OUTCOME_UNKNOWN`) |
| `robot_status.json` | `nhm --robot-status` |

`tests/unit/test_nhm_caller_fixtures.sh` checks each fixture against
`upstream_checks.py`, and checks that changed fixtures fail.
