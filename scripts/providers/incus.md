# ACFS in an Incus container

Run ACFS without renting a VPS. `scripts/providers/incus.sh` creates an unprivileged Ubuntu system container with [Incus](https://linuxcontainers.org/incus/), installs ACFS inside it, and prints what the machine you work from needs to attach to it as a herdr remote machine. With `--vm` it creates a VM instead ([below](#a-vm-instead-of-a-container)).

The installer runs **inside the container**, never on the machine that runs Incus (the hypervisor, called the host below).

---

## What you need

- **A Linux host with Incus whose API has what a container needs:** the sub-path volume mounts (`disk_volume_subpath`), the `sysinfo` intercept (`container_syscall_intercept_sysinfo`) and restricted project networks (`projects_networks_restricted_access`). The launcher reads the server's `api_extensions` before it creates anything and names the missing one; it never judges by the version string. Ubuntu 26.04's own Incus 6.0.5 qualifies; it lacks the optional `instance_limits_oom` and `container_disk_tmpfs`, which the launcher notes and the profile then leaves unused. Check that `incus info` works for you; on many hosts that means being in `incus-admin`. A VM (`--vm`) needs `/dev/kvm` as well.
- **Host setup, once:** `scripts/providers/incus.sh host-setup --storage <path|pool>` ([below](#host-setup)). Every launcher run reads what it records and stops without it. The launcher uses the default profile's managed bridge (`incusbr0`) for the NIC.
- **A clone of this repository on that host.** The launcher installs the clone's committed `HEAD`.
- **`git`, `jq` and `ssh-keygen` on that host.**
- **The public key of the machine you'll attach from,** usually your laptop's `~/.ssh/id_ed25519.pub`. Copy it to the host first. The host's own key is the wrong one when you attach from somewhere else.

## Host setup

Run it once on the host, as a user who can administer Incus there:

```bash
scripts/providers/incus.sh host-setup --storage /srv/incus --memory 96GiB
```

**`--storage` is required and has no default.** On a terminal it asks; otherwise it refuses. It takes one of:

| You give | Pool | Are the sizes enforced? |
|---|---|---|
| The name of an existing Incus pool | that pool | as its driver does (`incus storage list` shows it) |
| A directory on btrfs | a new `btrfs` pool there | yes |
| A directory on anything else | a new `dir` pool there | only on ext4 or XFS with project quotas turned on; otherwise not, and host setup warns |

The new pool is called `acfs` unless you pass `--pool-name`. ACFS formats no disk and adds no swap: how the host's disks and swap are laid out is your decision. To get enforced sizes on a spare disk, make a ZFS or btrfs pool on it yourself (`incus storage create …`) and pass its name.

**What it creates,** each only when absent:
- **The profile `acfs-swarm`,** policy only: the security pins ([below](#the-containers-shape)), the `sysinfo` intercept, `limits.processes=30000`, `limits.kernel.nofile=1048576`, autostart, and the CPU rule. A container sees every host thread (no `limits.cpu`) and yields under contention: `limits.cpu.priority=0` and `limits.cpu.allowance=30%`, which Incus turns into a `cpu.weight` of 20 against the 100 of the host's own services.
- **Memory,** with `--memory SIZE`: `limits.memory` on the profile. It is soft (the container is throttled and reclaimed, nothing is killed) when the host has swap, and hard (killed inside the container at the limit) when it has none; `--memory-enforce soft|hard` overrides that. Without `--memory` there is no limit.
- **The egress ACLs** `acfs-swarm-egress` and `acfs-vm-egress` ([The network](#the-network)). `--rch-worker ADDR` (repeatable) lets the containers reach an rch build worker over SSH.
- **The test project** `acfs-tests` on its own bridge `acfstest0` ([below](#the-test-project)), and with `--client-cert FILE --client-name NAME` a client certificate trusted for that project only.
- **`~/.config/acfs/incus.env`** (`$XDG_CONFIG_HOME/acfs/incus.env`): `ACFS_INCUS_POOL`, `ACFS_INCUS_STORAGE_SOURCE`, `ACFS_INCUS_PROJECT` and `ACFS_INCUS_BRIDGE_TESTS`. The launcher reads it on every run and stops without it.

**Re-running it is safe.** What exists is checked against what these options would create and never changed: a difference stops the run and names the object, so change an existing profile or ACL yourself with `incus profile set` or `incus network acl edit`. Host setup never deletes anything.

## Create the container

```bash
scripts/providers/incus.sh dev --ssh-key laptop.pub --jump myhost
```

- `dev` is the container's name.
- `--jump myhost` is how your laptop reaches this host over SSH: a `Host` from your laptop's `~/.ssh/config`. Leave it out when you'll attach from the Incus host itself.
- **Time:** for a VM, 10 to 12 minutes in all. Three complete runs took 616 to 697 s from the command to the printed block, with the image already cached (a one-time check on 2026-10-09). About half a minute of that is the VM booting. A container has not been timed yet.
- **Output:** the installer's output streams to stderr. When it's done, stdout carries only this block:

```
# Add to ~/.ssh/config on the machine you attach from, ABOVE any "Host *" block:
Host dev
    HostName 192.0.2.20
    User ubuntu
    ProxyJump myhost
    HostKeyAlias dev
    StrictHostKeyChecking yes
    ForwardAgent no
# Add to ~/.ssh/known_hosts on that machine:
dev ssh-ed25519 AAAA…
# Then run there (dev runs herdr 0.9.3):
herdr machine add dev
```

On your laptop:
1. Paste the `Host` entry into `~/.ssh/config`, **above** any `Host *` block. SSH uses the first value it finds for each option, so this entry's `ForwardAgent no` has to come before a `Host *` that turns forwarding on.
2. Paste the `known_hosts` line into `~/.ssh/known_hosts`. The launcher read the container's host key over Incus, so you never accept an unknown key on first connect.
3. Run `herdr machine add dev`.

**What the container gets.** Policy comes from the profile `acfs-swarm` that host setup made: the security pins below, the limits, the `sysinfo` intercept. What is per machine comes from the launcher, on the pool named in `incus.env`, all before the first boot:

| | Default | Option |
|---|---|---|
| Root disk | 40 GiB (where the pool enforces sizes) | `--root-size` |
| `acfs-state-dev`, a custom volume mounted by sub-path: `home/` at `/home/ubuntu` (1000:1000, 0700), `root/ssh-host/` at `/etc/ssh/acfs-host-keys`, `root/tailscale/` at `/var/lib/tailscale`, `.acfs/` at `/etc/acfs/state` (root, 0700) | 20 GiB | `--state-size` |
| `dev-data`, a custom volume at `/data` | 60 GiB | `--data-size` |
| Egress ACL on the NIC | `acfs-swarm-egress` | `--acl` |

The state volume is why a rebuild keeps the logins: every tool's state is under the home, and the home is on the volume, not on the root disk. An install that stopped on a checksum failure near its end had used 12 GiB of the root (a VM, one-time check, 2026-10-09). The options apply only when the instance is created. To resize later:

```bash
incus stop dev
incus config device set dev root size=80GiB
incus storage volume set <pool> dev-data size=200GiB
incus start dev
```

The limits are the profile's: change them there (`incus profile set acfs-swarm limits.memory=…`) for every container, or on one instance with `incus config set dev …`, which overrides the profile.

## Run it again

Re-running the same command is safe:

| The instance… | The launcher… |
|---|---|
| doesn't exist | creates it, installs ACFS, prints the block. A volume of the same name that already exists is reused as it is, never resized. |
| was created by the launcher, but its install never finished | starts it if it's stopped, and runs the installer again, which resumes where it stopped |
| is installed | starts it if it's stopped and prints the block again. **It never reinstalls.** Update ACFS inside the container with `acfs update`. |
| is anything else | refuses, exits 2, and doesn't start, copy into or run anything in it |

- **How it decides,** before it touches the instance, by two keys on it:
  - `user.acfs.install-started`, set when the launcher has created the instance and attached its volumes, and again before each installer run;
  - `user.acfs.installed`, set only when the installer exits 0. ACFS's own `state.json` can list a failed install as complete, so the launcher doesn't read it.
- **`user.acfs.provider=incus`** is also set at creation, as a label: `incus list user.acfs.provider=incus` lists the launcher's instances. The launcher doesn't decide by it. An instance that carries only this label is also what a creation leaves when it stopped between `incus init` and the first start; the launcher refuses it rather than boot it without its volumes. Delete it and re-run: the volumes are kept and reused.
- **`user.acfs.lease`** is set on a container before its first start: a random token that the container claims into its state volume on first boot, so that one volume serves one running instance. An instance started on a volume that holds another instance's lease doesn't start its user manager. The launcher never prints the token. To keep a login when the old instance is gone, use `acfs machine up --replace` or `incus rebuild`, which keep the key; a plain re-create gets a new token.
- **An instance you installed ACFS in yourself:** to have the launcher print its block, mark it installed with `incus config set dev user.acfs.installed=<commit>`. That's a promise: from then on the launcher never touches that instance's install, so set it only for an install that finished.
- **If the install fails, or you stop it with Ctrl-C:** Ctrl-C stops the installer inside the container too. The container is kept, and the block leaves out the `herdr machine add` line, because herdr may not be installed yet. Ignore the installer's own resume hint, which names a GitHub URL; re-run the launcher instead.
- **Uncommitted changes aren't installed.** The launcher archives the committed `HEAD`, through the installer's own `--bootstrap-archive` option, and warns when the checkout has changes it leaves out.
- **Stop or remove:** `incus stop dev`, or `incus delete dev`. The launcher never deletes anything: the volumes outlive the instance, and `incus storage volume delete <pool> acfs-state-dev` is your call.

## What reaches the container

- **SSH keys:** only the public keys you pass with `--ssh-key`, for the `ubuntu` user. `--ssh-key` is ignored when the instance already exists. Add keys later with `ssh-copy-id` from a machine that can already log in, or on the Incus host with `incus exec dev -- bash -c 'cat >> /home/ubuntu/.ssh/authorized_keys' < key.pub`.
  - **Keep the first line of `authorized_keys`.** The installer copies root's keys into ubuntu's file, so each key also appears a second time, behind cloud-init's forced command for root, which asks you to log in as `ubuntu` instead and disconnects. sshd uses the first line that matches, so if you delete or reorder the plain one, every login gets that message.
- **The code:** the archive of the committed `HEAD`, and the installer from that commit.
- **Two settings:** the installer's `TARGET_USER=ubuntu` and `ACFS_REPO_OWNER=arosl`.
- **Nothing else:**
  - no disk or folder of the host is shared: the two volumes are Incus custom volumes on the pool, not host paths;
  - no host devices (no `/dev/net/tun`, no `/dev/kvm`);
  - no host environment variables;
  - no API keys or agent logins.

  Log the agents in inside the container (`onboard`). Each container gets its own credentials: a GitHub key or fine-grained token for that container only. They live on its state volume and survive a rebuild.
- **Agent forwarding is off.** The printed entry carries `ForwardAgent no`, so root in the container can't use your laptop's SSH agent.
- **Passwords:** the `ubuntu` and root accounts have none, so only key logins work. The container runs Ubuntu's stock `sshd_config`.

## The network

The instance sits on Incus's NAT bridge, so nothing outside reaches it except through SSH on the host.

**In the other direction,** an instance on a plain bridge can reach the host and everything the host can route to: its LAN, and its tailnet when the host runs Tailscale. The launcher limits that with an Incus network ACL on the instance's NIC:
- **A container gets `acfs-swarm-egress`,** which host setup creates: the internet passes, and of the private ranges only the host's Incus API, the test project's bridge and the configured rch build workers. The launcher doesn't create it, since its allows name addresses only host setup knows; without it the launcher stops before creating anything.
- **A VM gets `acfs-vm-egress`.** It rejects outgoing traffic to `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` (CGNAT, which includes tailnets), `169.254.0.0/16`, `fc00::/7` and `fe80::/10` (IPv6 link-local, on which the host and every other instance on the bridge are reachable). The launcher creates it on the first run if it doesn't exist.
- **`--acl <name>`** puts another existing ACL on the NIC instead, for either type.
- **Everything else passes,** including the internet and the replies to your SSH sessions. The bridge's own DNS and DHCP pass too: Incus allows its own services ahead of any ACL. The launcher never changes an existing ACL.
- **Where it applies:** the instance's own NIC (`security.acls`). Other instances aren't affected.
- **It needs a managed bridge.** On any other network, the launcher stops before creating the instance.
- **What it doesn't cover:** the host's addresses outside those ranges, such as a public IP, stay reachable from the instance. The host's sshd still needs a key the instance doesn't have.
- **Agent Mail:** the agents in the container use the Agent Mail that ACFS installs inside it, so they don't need the host's.
- **To lift it for one instance,** when it needs a service on the host:

  ```bash
  incus config device unset dev eth0 security.acls
  ```

  `eth0` is the NIC's name in the default profile; `incus config device show dev` lists it. It takes effect on the running instance. Afterwards `dev` reaches everything the ACL rejected: the host on every address, its LAN and its tailnet. Other instances keep theirs. Re-running the launcher doesn't put it back; `incus config device set dev eth0 security.acls=acfs-swarm-egress` (or `acfs-vm-egress`) does, also on the running instance.

## herdr versions

- **Nothing is pinned.** ACFS installs the latest herdr release into `~/.local/bin` in the container, and the printed block names that version.
- **What herdr does about a version mismatch** (herdr v0.9.3, [Connecting machines](https://herdr.dev/docs/connecting-machines/) and [Remote attach](https://herdr.dev/docs/persistence-remote/)):
  - The client and the container's server negotiate compatibility; their versions don't have to match.
  - If they aren't compatible, an interactive `herdr machine add dev`, or `herdr --remote dev`, offers to install the client's version in the container. It asks before it stops a running server, and the default answer is No.
  - Background reconnects never install anything. They show **Attention** until you run that interactive setup.
  - Updating your laptop's herdr doesn't touch the container's server. `acfs update` inside the container updates its herdr; the running server keeps its version until it restarts.
- **`~/.local/bin` isn't on the PATH of a non-interactive SSH command** in the container. herdr's own discovery looks there, but a bare `ssh dev herdr` doesn't find it. Use `ssh dev .local/bin/herdr`.

## The container's shape

**Settings the launcher pins** on every container, whatever the profiles say:
- `security.privileged=false`: root in the container is an ordinary, unprivileged uid on the host;
- `security.nesting=false`: no Incus or Docker inside it;
- `security.idmap.isolated=true`: each such container gets its own block of host uids and gids (65536 by default), so root in one ACFS container is no uid of another.

The profile `acfs-swarm` carries the same pins, the limits and the `sysinfo` intercept, and no device: what is per machine (the root size, the volumes, the ACL on the NIC) is on the instance, set by the launcher. The profiles applied are `default` (for the NIC and the root device) and `acfs-swarm`, in that order.

### What a container gives up against a VM

- **It shares the host's kernel.** The agents run with passwordless sudo in vibe mode, so they are root in the container. That root is unprivileged on the host, but the container's processes call the host kernel directly, and a kernel bug they can reach is a way onto the host. A VM runs its own kernel, behind KVM's much smaller interface. **Where agents run with loose permissions on a host you care about, use the VM.**
- **No kernel tunables, modules or swap.** The installer uses none: a read of `install.sh`, `scripts/lib/` and the generated installers on 2026-10-09 found no swap, sysctl, modprobe, mount, fstab, AppArmor or firewall step. Not yet confirmed by a real install in a container.
- **Tailscale installs but can't connect from inside.** An unprivileged container has no `/dev/net/tun`, so `tailscaled` can't make its interface and `sudo tailscale up` fails. Attaching through the printed SSH entry doesn't need Tailscale; to put the machine on your tailnet, use the sidecar ([below](#the-tailnet-a-sidecar)), not `/dev/net/tun` in the container.
- **The disk sizes depend on the storage pool.** On a `btrfs`, `zfs` or `lvm` pool, the root size and the volume sizes are enforced. On a `dir` pool they are enforced only on ext4 or XFS with project quotas. Otherwise Incus skips them with only a warning in its own log, and the container can fill the host's disk. `incus storage list` shows the driver; host setup warns when it makes a pool without enforced quotas.
- **Memory:** the profile's `limits.memory` caps it. With `limits.memory.enforce=soft` the kernel throttles and reclaims above the limit and kills nothing; with the default, hard enforcement, it kills inside the container at the limit. `free` inside shows the limit, not the host's RAM, through the `sysinfo` intercept.

### Startup, disk and RAM

`tests/vm/test_incus_provider.sh <name>` and `tests/vm/test_incus_provider.sh --vm <name>` each end by printing the instance's disk and memory use once installed, and the time from `incus start` to an SSH login. Run both on one host to compare. **No container run yet:** the container mode was written on a machine without Incus (2026-10-09, and again on 2026-10-10 for the profile, the volumes and the lease), so it is tested only against a stub `incus`. Two things a real run has to confirm: that cloud-init makes the `ubuntu` home on the mounted volume with the shell files the installer expects (the directory exists before the user does, so `useradd` copies no skeleton), and that `initial.uid` and `initial.gid` on the whole `dev-data` volume make `/data` the user's (the Incus documentation describes them for sub-paths).

## A swarm machine

A container the launcher makes is a swarm machine: one host can run several, each with its own logins, and they share the host through the profile's soft limits.

- **Kept apart:** each has its own uid and gid range (`security.idmap.isolated`), its own two volumes, its own lease, and its own egress ACL on its NIC.
- **Inside,** the installer sets it up for a container:
  - `/tmp` stays on the root disk, not RAM, so it isn't charged to the container's memory. The agents' `TMPDIR` is `/data/tmp`, on the data volume. `acfs agents sweep` cleans both.
  - The lease unit and the sshd `HostKey` drop-in for the state volume ([below](#logins-survive-a-rebuild-the-state-layer)).
- **`acfs doctor` in a container** recognises it (`container.virt`). It checks the container's `memory.current` against its limit, `/tmp` on disk, `TMPDIR` on the data volume, linger, the acfs slices, and the state layer's lease and modes. It only reads.
- **Not built yet:** `acfs machine up|verify`, one command for a machine on either target with an authenticated login check (acfs-ioo3.4). Until then, use the launcher and the commands on this page.

## Logins survive a rebuild: the state layer

Everything a login needs is on the state volume `acfs-state-<name>`: the whole home, the SSH host keys and Tailscale's state ([the table above](#create-the-container)). Rebuilding the instance (`incus rebuild`) or replacing it keeps them, as long as the volume moves with it. `acfs state` works on that layer from inside the machine; on a VPS the same paths are plain directories and the same commands apply.

```bash
sudo acfs state export dev --recipient age1…     # an age-encrypted archive of the logins and sessions
sudo acfs state import dev ~/acfs-state/dev-….tar.age --identity key.txt
acfs state export dev --dry-run                     # what would go, including unknown dot-directories
sudo acfs state repair                              # fix modes and owners, row by row
acfs state doctor                                   # read-only; acfs doctor runs it
acfs state manifest                                 # the rows: logins, cache and root
```

- **Export** takes a lock, stops every process that writes login or session state (or refuses while one still runs), and streams `tar | age` to a 0600 file under `~/acfs-state/`, published by an atomic rename. Nothing is written in plain text. It needs `--recipient` or `--recipients-file`. Caches such as cass's index stay out unless `--with-cache`. On Incus, `--snapshot-pool <pool>` first snapshots the volume through the `host` remote.
- **A move, not a backup:** `--move` marks the archive as a move. This machine gives up the login, stays quiesced and is fenced; `acfs state lease reclaim` takes it back if the move is called off.
- **Import** validates the archive, unpacks it into a staging area on the volume, sets owners and modes per row (root's rows stay root's), then swaps it in and writes the lease. It refuses a machine that already holds a login unless `--replace`. It is journalled: `--resume` finishes an interrupted import, and a failed one leaves the machine's existing login usable.
- **The lease: one running machine per state volume.** Codex expects one `auth.json` per machine, so two instances on one volume would fight over its refresh. The launcher puts a random token on the instance (`user.acfs.lease`). On first boot the container claims it into the volume. At every boot, a unit that runs before the user manager compares the two and refuses to start the user's services on a mismatch. `acfs state lease status` shows it.
- **A second machine gets its own logins.** Copying one machine's archive into a second running one would share the login; log the second in itself.
- **Never** commit an archive, mail it or upload it anywhere. Move it with `scp`.

## The tailnet: a sidecar

```bash
scripts/providers/incus.sh tailscale dev --auth-key-file ~/ts-authkey
```

This puts the machine on your tailnet without Tailscale in it. A small container next to it, `acfs-ts-dev`, logs into the tailnet and forwards tailnet TCP port 22 to the machine's sshd (`--port PORT`, repeatable, forwards more). It prints the sidecar's tailnet name, by default the machine's (`--hostname` changes it).

- **Why a sidecar:** the node key stays out of the container where agents run with sudo. The machine's egress ACL stays closed to `100.64.0.0/10`. And the machine can be rebuilt while its tailnet name and node stay.
- **No host devices:** `tailscaled` runs in userspace networking, so neither container needs `/dev/net/tun`.
- **The auth key** goes in on stdin, into a file only root can read, and is removed once `tailscale up` returns. It is never in a command line or in the output. It is needed only until the sidecar is logged in: the node's state is on the sidecar's own volume, `acfs-ts-dev-state`, which survives a rebuild of the sidecar.
- **The sidecar's NIC** carries `acfs-vm-egress`, so it reaches the internet (the coordination server and DERP) and no private range.
- **Re-running** reuses the sidecar if it belongs to this machine, keeps its login and forwards, and refuses to change a different forward on a port. The machine itself is never changed.

## The test project

Tests that need their own Incus instances run them in `acfs-tests`, a project that host setup restricts:
- **Restrictions:** no nesting, no privileged or shared-idmap containers, no syscall interception, no unix-char or GPU devices, disks and NICs only from managed pools and networks, only the bridge `acfstest0`, images only from `images.linuxcontainers.org`, and no snapshots or backups.
- **Limits:** 6 instances, 16 CPUs, 32 GiB of memory and 200 GiB of disk in all. Its default profile gives each instance 4 CPUs and 8 GiB, because a project with limits refuses instances that set none. Host setup sets these limits only when they are unset, so changes you make are kept.

**To let a machine use it:**
1. **The certificate:** inside the machine, any `incus` command (`incus remote list`) creates its client certificate, `~/.config/incus/client.crt`. Copy that file to the host.
2. **Trust it:** on the host, `incus.sh host-setup … --client-cert client.crt --client-name dev`. The certificate is trusted for `acfs-tests` only.
3. **Expose the API:** host setup doesn't make Incus listen on the network. Set `core.https_address` to the gateway address of the machine's bridge, port 8443, and allow that port in the host's firewall. `acfs-swarm-egress` already lets the containers reach exactly that address and port.
4. **Add the remote:** inside the machine, `incus remote add host https://<gateway>:8443`. Before you accept the server's certificate, compare its fingerprint with the host's own `incus info`. The machine then reaches the instances on `acfstest0` over SSH and ping, and nothing else of the host's.

A run of `tests/vm/test_incus_provider.sh` through such a remote, which would also check what the certificate is refused, is acfs-ioo3.11.

## Next to podman

A host that also runs podman deployments shares its firewall, address space, uid ranges, storage and memory with Incus. Neither stack configures the other, so check the overlaps yourself:

| What | Incus | Podman | Check |
|---|---|---|---|
| Firewall | its own nftables table per managed bridge | netavark's table, or an older backend | after any firewall or service restart, from both stacks: DNS, outbound HTTPS and SSH still work, and a private address the ACL rejects is still rejected, over IPv4 and IPv6 |
| Subnets | `incusbr0`, `acfstest0` | `podman0` (`10.88.0.0/16`) and each network's | no overlap with each other, a VPN or the tailnet: `ip route`, `incus network show <bridge>`, `podman network inspect <net>` |
| uid and gid ranges | root's `/etc/subuid` entry; 65536 per isolated container | rootless: each user's entry; `--userns=auto`: the `containers` entry | disjoint: `/etc/subuid`, `/etc/subgid`, `incus config get dev volatile.idmap.current` |
| Storage | the pool | `/var/lib/containers`, `~/.local/share/containers` | separate filesystems, or enforced sizes on the pool |
| Memory | the profile's limit | each deployment's limits | budget both together |
| Host ports | proxy devices | published ports | one owner per port |

A doctor check that runs these flows is acfs-ioo3.16.

## A VM instead of a container

```bash
scripts/providers/incus.sh dev --ssh-key laptop.pub --jump myhost --vm
```

- **What you get:** a VM from the same cloud image, with its own kernel behind KVM, the launcher's fixed limits (4 vCPUs, 8 GiB of RAM, a 40 GiB root on the pool, `--root-size` to change it), the egress ACL `acfs-vm-egress`, the same keys and the same attach block. No profile beyond `default`, no state or data volume, no lease: its home is on its root disk, and a rebuild loses the logins.
- **It needs `/dev/kvm`** on the host, and no particular Incus version: the launcher's server check is for containers.
- **The type is fixed at creation.** On a re-run, an existing instance keeps its type, its ACL and its sizes: `--vm`, `--acl` and the size options on an existing instance are ignored with a warning.
- **To resize later:** `incus stop dev; incus config set dev limits.cpu=8 limits.memory=16GiB; incus config device set dev root size=80GiB; incus start dev`.
- `--vm` stays until the devbox has moved to a container and its rollback window has closed; then it goes.

## Incus on another host (unverified)

Prefix the name with an Incus remote, set up with `incus remote add`:

```bash
scripts/providers/incus.sh far:dev --ssh-key laptop.pub --jump farhost
```

- Every Incus call goes to the remote: the server check, the image, the instance, the volumes, the profile and ACL lookups, and the install.
- `~/.config/acfs/incus.env` is read on the machine you run the launcher from, and the pool it names must exist on the remote.
- `--jump` names that remote host as your laptop reaches it over SSH.
- The block names the instance `dev`, without the remote.
- This is tested only against a stub `incus`. No second Incus host was available.

## Colima on a Mac (unverified)

Untested, because there was no Mac. What should apply:
- **Nested virtualization:** Colima's Incus runtime (`colima start --runtime incus`) runs Incus inside a Linux VM, so an Incus VM there is a VM inside a VM. Colima's README says that needs Apple Silicon M3 or newer, and the flag differs between Colima versions.
- **The home share:** Colima mounts your home directory into its own VM by default, so start it with a narrower `--mount`. The launcher's disk devices are Incus volumes on the pool, never host paths, so that share never reaches the ACFS instance, but it does reach Colima's VM.
- **The jump host:** reach the Colima VM with `colima ssh-config >> ~/.ssh/config`, then pass `--jump colima`.
- **The launcher needs bash 4 or newer** (macOS ships 3.2), plus `jq`.
- Whether Colima's Incus network is a managed bridge, which the ACL needs, and whether its Incus has the API extensions a container needs, is unverified.

## Known limits

- **The IP isn't pinned.** If the instance's address changes, SSH fails loudly on the host key, through `HostKeyAlias` and strict checking. Re-run the launcher to print the new address.
- **GitHub's API rate limit is shared.** The install fetches release data from GitHub's API. Without a token, GitHub allows 60 requests an hour per public IP, and every instance on one host reaches GitHub through the host's IP. Several installs in an hour can use it up. On 2026-10-09, a day of test installs from one host did, and the next install failed in its stack phase with 403s and "Failed to fetch version information". The launcher then keeps the instance as an unfinished install. `curl -s https://api.github.com/rate_limit` shows when the limit resets; re-run the launcher after that to resume.

## Tests

- `bash tests/unit/test_incus_provider_stub.sh`: the launcher's calls and output, against a stub `incus`.
- `bash tests/unit/test_incus_host_setup.sh` and `bash tests/unit/test_incus_tailscale.sh`: host setup and the sidecar, against the same stub.
- `bash tests/unit/test_state_layer.sh`: `acfs state` against a fixture home and volume.
- `tests/vm/test_incus_provider.sh [--vm] <new-name>`: a real container, or with `--vm` a real VM, checked through the printed block, then measured. It's opt-in and runs a full ACFS install, and it skips with the reason when Incus, KVM (for a VM) or `images:` isn't available. A container run needs host setup first.
