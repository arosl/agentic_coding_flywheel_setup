# ACFS in an Incus container

Run ACFS without renting a VPS. `scripts/providers/incus.sh` creates an unprivileged Ubuntu system container with [Incus](https://linuxcontainers.org/incus/), installs ACFS inside it, and prints what the machine you work from needs to attach to it as a herdr remote machine. With `--vm` it creates a VM instead ([below](#a-vm-instead-of-a-container)).

The installer runs **inside the container**, never on the machine that runs Incus (the hypervisor, called the host below).

---

## What you need

- **A Linux host with Incus whose API has what a container needs:** the sub-path volume mounts (`disk_volume_subpath`), the `sysinfo` intercept (`container_syscall_intercept_sysinfo`) and restricted project networks (`projects_networks_restricted_access`). The launcher reads the server's `api_extensions` before it creates anything and names the missing one; it never judges by the version string. Ubuntu 26.04's own Incus 6.0.5 qualifies; it lacks the optional `instance_limits_oom` and `container_disk_tmpfs`, which the launcher notes and the profile then leaves unused. Check that `incus info` works for you; on many hosts that means being in `incus-admin`. A VM (`--vm`) needs `/dev/kvm` as well.
- **Host setup, once:** `scripts/providers/incus.sh host-setup --storage <path|pool>`. It makes the storage pool from the location you give, the policy profile `acfs-swarm`, the egress ACLs, the test project, and writes the pool's name to `~/.config/acfs/incus.env` (`$XDG_CONFIG_HOME/acfs/incus.env`). Every launcher run reads that file and stops without it. The launcher uses the default profile's managed bridge (`incusbr0`) for the NIC.
- **A clone of this repository on that host.** The launcher installs the clone's committed `HEAD`.
- **`git`, `jq` and `ssh-keygen` on that host.**
- **The public key of the machine you'll attach from,** usually your laptop's `~/.ssh/id_ed25519.pub`. Copy it to the host first. The host's own key is the wrong one when you attach from somewhere else.

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
- **Tailscale installs but can't connect.** An unprivileged container has no `/dev/net/tun`, so `tailscaled` can't make its interface and `sudo tailscale up` fails. Attaching through the printed SSH entry doesn't need Tailscale. The launcher adds no host devices; the planned way in is a Tailscale sidecar container next to the machine, not `/dev/net/tun` in it.
- **The disk sizes depend on the storage pool.** On a `btrfs`, `zfs` or `lvm` pool, the root size and the volume sizes are enforced. On a `dir` pool they are enforced only on ext4 or XFS with project quotas. Otherwise Incus skips them with only a warning in its own log, and the container can fill the host's disk. `incus storage list` shows the driver; host setup warns when it makes a pool without enforced quotas.
- **Memory:** the profile's `limits.memory` caps it. With `limits.memory.enforce=soft` the kernel throttles and reclaims above the limit and kills nothing; with the default, hard enforcement, it kills inside the container at the limit. `free` inside shows the limit, not the host's RAM, through the `sysinfo` intercept.

### Startup, disk and RAM

`tests/vm/test_incus_provider.sh <name>` and `tests/vm/test_incus_provider.sh --vm <name>` each end by printing the instance's disk and memory use once installed, and the time from `incus start` to an SSH login. Run both on one host to compare. **No container run yet:** the container mode was written on a machine without Incus (2026-10-09, and again on 2026-10-10 for the profile, the volumes and the lease), so it is tested only against a stub `incus`. Two things a real run has to confirm: that cloud-init makes the `ubuntu` home on the mounted volume with the shell files the installer expects (the directory exists before the user does, so `useradd` copies no skeleton), and that `initial.uid` and `initial.gid` on the whole `dev-data` volume make `/data` the user's (the Incus documentation describes them for sub-paths).

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
- `tests/vm/test_incus_provider.sh [--vm] <new-name>`: a real container, or with `--vm` a real VM, checked through the printed block, then measured. It's opt-in and runs a full ACFS install, and it skips with the reason when Incus, KVM (for a VM) or `images:` isn't available. A container run needs host setup first.
