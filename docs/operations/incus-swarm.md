# Moving a dev machine into an Incus swarm machine

Related: [index](../index.md), [`scripts/providers/incus.md`](../../scripts/providers/incus.md) (the guide: host setup, the launcher, the state layer, the sidecar)

How to move a running ACFS dev machine, a VM or a VPS with a swarm on it, into a swarm machine: an Incus container that `scripts/providers/incus.sh` makes. The old machine is called `old` and the new one `dev` below; put in your own names. Steps 0 to 3 run beside the working swarm, and the downtime is steps 4 to 7: about one to two hours, most of it checking and restarting agents.

## 0. Before you start

- **Free space** on the old machine and on the pool. The first copy needs room for everything under `/data` that you keep. Clear temporary files first (`acfs agents sweep --dry-run`, then without it), after listing the worktrees and plan directories you still need (`git worktree list` in each repository).
- **Decide what moves.** By default: `/data/projects`, the worktrees you listed, plan and cache directories you still use, and the logins (step 5). Toolchains (`~/.rustup`, `~/.cargo`, `~/.bun`, `~/.nvm`, `~/.acfs`, `~/.local/bin`) don't move; the new install owns them. Neither do `/tmp`, `~/.cache` or the old kernel and boot files.
- **The old machine needs `acfs state`,** which step 5 uses. If `acfs state manifest` fails there, update its ACFS first (`acfs update`). On a VM or VPS the state layer works on plain directories.
- **Check the uid and gid** of the old machine's user (`id`). The new machine's `ubuntu` is 1000:1000; if the old one differs, map it in the copies (`--usermap`, `--groupmap`).

## 1. The host

Once, on the host: `incus.sh host-setup --storage <pool|directory> [--memory SIZE]`, sized for the new machine and anything else that will run there. Also anything you want beyond it: `core.https_address` for the test project, or swap. See the guide's "Host setup".

## 2. Create and check the new machine

```bash
scripts/lib/machine.sh up dev --ssh-key laptop.pub --jump <host> --state-size <size> --data-size <size>
```

(`acfs machine up` where acfs is installed; either hands everything to `incus.sh`, so calling `scripts/providers/incus.sh dev …` directly is the same.)

The volumes are sized at creation, so give them room for what step 3 copies. When it has finished, log in and run `acfs doctor`. **This is a fresh install, so it is also the product test:** fix what fails in ACFS before you go on, not by hand in the machine. Install what the old machine had beyond ACFS, such as a database you still use.

## 3. First copy, live, nothing deleted

The two machines can't reach each other by default: each one's egress ACL rejects private addresses. For the move, open one path and close it again afterwards:
- **The old machine is an instance on the same host:** lift its ACL (`incus config device unset old eth0 security.acls`, see the guide's "The network"), and put a key of the old machine in the new one's `~/.ssh/authorized_keys`.
- **The old machine is a VPS:** it reaches the new one through the host, with the host as SSH jump.

From the old machine, list first, then copy:

```bash
rsync -aAXH --dry-run --itemize-changes /data/projects/ dev:/data/projects/
rsync -aAXH --info=progress2 /data/projects/ dev:/data/projects/
```

Repeat for each other directory in your list. Never pass `--delete` here: a deleting copy needs its own, separate decision.

## 4. Freeze

1. Record the agents: `herdr agent list` (name, kind, pane, cwd, session), so you can resume the ones worth resuming.
2. Stop handing out work. Let each agent finish its step, commit, leave a handoff on its bead and release its reservations; then `br sync --flush-only`.
3. Stop every writer: the user services (`systemctl --user list-units 'acfs-*' 'agent-mail*'` shows them), then `herdr server stop`. Check that no `claude`, `codex`, `am`, `cass`, `cm`, `herdr` or `node` process of the user is left (`pgrep -u "$USER" -a`). Dump any database you moved with its own tool.

Downtime starts here.

## 5. Delta copy and the logins

1. Run step 3's copies again: now they also pick up the databases, which are consistent because nothing writes them.
2. Move the logins with the state layer, as a move: the old machine gives them up and is fenced.

   ```bash
   # on old
   sudo acfs state export old --move --recipient <age recipient>
   scp ~/acfs-state/old-*.tar.age dev:
   # on dev
   sudo acfs state import dev ~/old-*.tar.age --identity <age identity file>
   ```

   Import refuses a machine that already holds a login. A fresh one holds none unless you logged in during step 2; then `--replace`.
3. From here the old machine must not run an agent again: Codex rotates its login, and two machines refreshing one would break it.

## 6. Start the new machine

1. `systemctl --user start` the services, then herdr.
2. Run `acfs doctor`: its state section checks the lease and the modes.
3. Check each login with one small request: `acfs machine verify dev` from the host (or `acfs machine verify` inside). It asks each configured tool once (`claude -p`, `codex login status` and `codex exec`, `gh auth status`, Agent Mail's agent list, and the others), checks the host key, the lease and that no login file sits outside the home, and says which tools aren't configured at all.
4. Clear the old pane mappings in Agent Mail (`cleanup_pane_identities`).
5. Respawn the agents: `claude --resume <id>` or `codex resume <id>` for those your list marked worth resuming (their transcripts are keyed by the working directory, which didn't change), and fresh agents for the rest.

## 7. Repoint

- Your laptop's `~/.ssh/config` entry and `herdr machine add` now point at the new machine (the launcher's block).
- If the old machine is an instance, put its ACL back, stop it and keep it from starting: `incus stop old` and `incus config set old boot.autostart=false`.
- Re-close the path you opened in step 3.

## 8. Rollback

Keep the old machine stopped for a while, two weeks for example, before you delete it.
- **Before step 7:** stop the new machine, then start the old one and reclaim its login there (`sudo acfs state lease reclaim`).
- **After step 7:** stop the new machine first. Its logins are the newest, so move them back with `acfs state export --move` from the new one and an import on the old one. Bring over deliberately what changed under `/data` since the move, then start the old one.
- **Never run both at once.**
