# Incus fixtures for `tests/unit/test_incus_provider_stub.sh`

**Real data or synthetic:** captured from real Incus, then trimmed and made host-neutral. This repo is public, so no fixture keeps an address, MAC or name of the host it was captured on.

All of them were captured on 2026-10-09 from Incus 6.0.5 (client and server), with one `images:ubuntu/26.04/cloud` VM. Each `list-*` state was produced for real, by setting or unsetting the `user.acfs.*` keys with `incus config set` or `unset` and starting or stopping the VM, never by editing the JSON.

| File | Captured with | State |
|---|---|---|
| `list-absent.json` | `incus list nosuchinstance -f json` | no such instance |
| `list-stopped-unmarked.json` | `incus list '^<vm>$' -f json` | stopped, no `user.acfs.*` keys |
| `list-stopped-marked.json` | same | stopped, `user.acfs.provider=incus` |
| `list-running-unmarked.json` | same | running, with an IPv4 lease, no `user.acfs.*` keys |
| `list-running-marked.json` | same | running, `user.acfs.provider=incus` |
| `list-running-installed.json` | same | running, plus `user.acfs.installed=<sha>` |
| `profile-default.json` | `incus query /1.0/profiles/default` | the profile `incus admin init --minimal` creates |
| `network-incusbr0.json` | `incus query /1.0/networks/incusbr0` | the managed bridge `incus admin init --minimal` creates |

**How they were trimmed:**

- `list-*`: kept `status`, `type`, the `user.*` config keys, and each interface's `addresses` (`family`, `address`, `netmask`, `scope`). Dropped everything else: volatile keys, the cloud-init user-data, counters, MACs and device names on the host.
- **Made host-neutral:**
  - the VM's name is replaced with `dev`;
  - its global IPv4 address with `192.0.2.20` (RFC 5737 documentation range);
  - its link-local IPv6 address with `fe80::20`.
- `profile-default.json`: kept `name` and `devices`.
- `network-incusbr0.json`: kept `name`, `managed` and `type`, and dropped `config` (the bridge's addresses).

**Synthetic, made by the test at run time and not stored here:** the VM's SSH host key (generated with `ssh-keygen`), the `herdr --version` line, the `ssh-keygen -l` line for `authorized_keys`, and the installer's output.

**To recapture:** create a VM with `scripts/providers/incus.sh`, run the commands above against it, and trim the output the same way.
