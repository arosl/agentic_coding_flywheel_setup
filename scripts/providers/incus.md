# ACFS on an Incus VM

Run ACFS without renting a VPS. `scripts/providers/incus.sh` creates an Ubuntu VM with [Incus](https://linuxcontainers.org/incus/), installs ACFS inside it, and prints what the machine you work from needs to attach to it as a herdr remote machine. With `--container` it creates an unprivileged system container instead ([below](#a-container-instead-of-a-vm)).

The installer runs **inside the VM**, never on the machine that runs Incus.

---

## What you need

- **A Linux host with Incus and KVM.** The VM needs `/dev/kvm` (a `--container` doesn't), so check `incus info` works for you; on many hosts that means being in `incus-admin`. A fresh `incus admin init --minimal` is enough: the launcher uses the default profile, its storage pool and its managed bridge (`incusbr0`).
- **A clone of this repository on that host.** The launcher installs the clone's committed `HEAD`.
- **`git`, `jq` and `ssh-keygen` on that host.**
- **The public key of the machine you'll attach from,** usually your laptop's `~/.ssh/id_ed25519.pub`. Copy it to the host first. The host's own key is the wrong one when you attach from somewhere else.

## Create the VM

```bash
scripts/providers/incus.sh dev --ssh-key laptop.pub --jump myhost
```

- `dev` is the VM's name.
- `--jump myhost` is how your laptop reaches this host over SSH: a `Host` from your laptop's `~/.ssh/config`. Leave it out when you'll attach from the Incus host itself.
- **Time:** 10 to 12 minutes in all. Three complete runs took 616 to 697 s from the command to the printed block, with the image already cached (a one-time check on 2026-10-09). About half a minute of that is the VM booting.
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
2. Paste the `known_hosts` line into `~/.ssh/known_hosts`. The launcher read the VM's host key over Incus, so you never accept an unknown key on first connect.
3. Run `herdr machine add dev`.

**Fixed settings:** the VM gets 4 vCPUs, 8 GiB of RAM and a 40 GiB disk. An install that stopped on a checksum failure near its end had used 12 GiB of that (one-time check, 2026-10-09). To resize later:

```bash
incus stop dev
incus config set dev limits.cpu=8 limits.memory=16GiB
incus config device set dev root size=80GiB
incus start dev
```

## Run it again

Re-running the same command is safe:

| The VM… | The launcher… |
|---|---|
| doesn't exist | creates it, installs ACFS, prints the block |
| was created by the launcher, but its install never finished | starts it if it's stopped, and runs the installer again, which resumes where it stopped |
| is installed | starts it if it's stopped and prints the block again. **It never reinstalls.** Update ACFS inside the VM with `acfs update`. |
| is anything else | refuses, exits 2, and doesn't start, copy into or run anything in it |

- **How it decides,** before it touches the VM, by two keys on the instance:
  - `user.acfs.install-started`, set when the launcher creates the VM and again before each installer run;
  - `user.acfs.installed`, set only when the installer exits 0. ACFS's own `state.json` can list a failed install as complete, so the launcher doesn't read it.
- **`user.acfs.provider=incus`** is also set at creation, as a label: `incus list user.acfs.provider=incus` lists the launcher's VMs. The launcher doesn't decide by it.
- **A VM you installed ACFS in yourself:** to have the launcher print its block, mark it installed with `incus config set dev user.acfs.installed=<commit>`. That's a promise: from then on the launcher never touches that VM's install, so set it only for an install that finished.
- **If the install fails, or you stop it with Ctrl-C:** Ctrl-C stops the installer inside the VM too. The VM is kept, and the block leaves out the `herdr machine add` line, because herdr may not be installed yet. Ignore the installer's own resume hint, which names a GitHub URL; re-run the launcher instead.
- **Uncommitted changes aren't installed.** The launcher archives the committed `HEAD`, through the installer's own `--bootstrap-archive` option, and warns when the checkout has changes it leaves out.
- **Stop or remove:** `incus stop dev`, or `incus delete dev`. The launcher never deletes anything.

## What reaches the VM

- **SSH keys:** only the public keys you pass with `--ssh-key`, for the `ubuntu` user. `--ssh-key` is ignored when the VM already exists. Add keys later with `ssh-copy-id` from a machine that can already log in, or on the Incus host with `incus exec dev -- bash -c 'cat >> /home/ubuntu/.ssh/authorized_keys' < key.pub`.
  - **Keep the first line of `authorized_keys`.** The installer copies root's keys into ubuntu's file, so each key also appears a second time, behind cloud-init's forced command for root, which asks you to log in as `ubuntu` instead and disconnects. sshd uses the first line that matches, so if you delete or reorder the plain one, every login gets that message.
- **The code:** the archive of the committed `HEAD`, and the installer from that commit.
- **Two settings:** the installer's `TARGET_USER=ubuntu` and `ACFS_REPO_OWNER=arosl`.
- **Nothing else:**
  - no disk or folder of the host is shared;
  - no host environment variables;
  - no API keys or agent logins.

  Log the agents in inside the VM (`onboard`). Each VM gets its own credentials: a GitHub key or fine-grained token for that VM only.
- **Agent forwarding is off.** The printed entry carries `ForwardAgent no`, so root in the VM can't use your laptop's SSH agent.
- **Passwords:** the `ubuntu` and root accounts have none, so only key logins work. The VM runs Ubuntu's stock `sshd_config`.

## The network

The VM sits on Incus's NAT bridge, so nothing outside reaches it except through SSH on the host.

**In the other direction,** a VM on a plain bridge can reach the host and everything the host can route to: its LAN, and its tailnet when the host runs Tailscale. The launcher limits that with an Incus network ACL:
- **The ACL is `acfs-vm-egress`.** It rejects outgoing traffic to `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` (CGNAT, which includes tailnets), `169.254.0.0/16`, `fc00::/7` and `fe80::/10` (IPv6 link-local, on which the host and every other instance on the bridge are reachable).
- **Everything else passes,** including the internet and the replies to your SSH sessions. The bridge's own DNS and DHCP pass too: Incus allows its own services ahead of any ACL.
- **When it's created:** on the first run, if it doesn't exist. The launcher never changes an existing one.
- **Where it applies:** it's attached to each launcher VM's NIC (`security.acls`). Other instances aren't affected.
- **It needs a managed bridge.** On any other network, the launcher stops before creating the VM.
- **What it doesn't cover:** the host's addresses outside those ranges, such as a public IP, stay reachable from the VM. The host's sshd still needs a key the VM doesn't have.
- **Agent Mail:** the agents in the VM use the Agent Mail that ACFS installs inside it, so they don't need the host's.
- **To lift it for one VM,** when that VM needs a service on the host:

  ```bash
  incus config device unset dev eth0 security.acls
  ```

  `eth0` is the NIC's name in the default profile; `incus config device show dev` lists it. It takes effect on the running VM. Afterwards `dev` reaches everything the ACL rejected: the host on every address, its LAN and its tailnet. Other VMs keep the ACL. Re-running the launcher doesn't put it back; `incus config device set dev eth0 security.acls=acfs-vm-egress` does, also on the running VM.

## herdr versions

- **Nothing is pinned.** ACFS installs the latest herdr release into `~/.local/bin` in the VM, and the printed block names that version.
- **What herdr does about a version mismatch** (herdr v0.9.3, [Connecting machines](https://herdr.dev/docs/connecting-machines/) and [Remote attach](https://herdr.dev/docs/persistence-remote/)):
  - The client and the VM's server negotiate compatibility; their versions don't have to match.
  - If they aren't compatible, an interactive `herdr machine add dev`, or `herdr --remote dev`, offers to install the client's version on the VM. It asks before it stops a running server, and the default answer is No.
  - Background reconnects never install anything. They show **Attention** until you run that interactive setup.
  - Updating your laptop's herdr doesn't touch the VM's server. `acfs update` inside the VM updates the VM's herdr; the running server keeps its version until it restarts.
- **`~/.local/bin` isn't on the PATH of a non-interactive SSH command** in the VM. herdr's own discovery looks there, but a bare `ssh dev herdr` doesn't find it. Use `ssh dev .local/bin/herdr`.

## A container instead of a VM

```bash
scripts/providers/incus.sh dev --ssh-key laptop.pub --jump myhost --container
```

- **What you get:** an unprivileged system container from the same image, with the same limits (4 CPUs, 8 GiB of RAM, 40 GiB of disk), the same egress ACL, the same keys and the same attach block. Everything above applies to it, with "container" for "VM".
- **No KVM needed,** so it runs on hosts without virtualization, such as a cloud VM without nested virtualization.
- **The type is fixed at creation.** On a re-run, an existing instance keeps its type: `--container` on an existing VM is ignored with a warning, and an existing container needs no `--container`.
- **Settings the launcher pins,** whatever the default profile says:
  - `security.privileged=false`: root in the container is an ordinary, unprivileged uid on the host;
  - `security.nesting=false`: no Incus or Docker inside it;
  - `security.idmap.isolated=true`: each such container gets its own block of host uids and gids (65536 by default), so root in one ACFS container is no uid of another.

### What a container gives up against a VM

- **It shares the host's kernel.** The agents run with passwordless sudo in vibe mode, so they are root in the container. That root is unprivileged on the host, but the container's processes call the host kernel directly, and a kernel bug they can reach is a way onto the host. A VM runs its own kernel, behind KVM's much smaller interface. **Where agents run with loose permissions on a host you care about, use the VM.**
- **No kernel tunables, modules or swap.** The installer uses none: a read of `install.sh`, `scripts/lib/` and the generated installers on 2026-10-09 found no swap, sysctl, modprobe, mount, fstab, AppArmor or firewall step. Not yet confirmed by a real install in a container.
- **Tailscale installs but can't connect.** An unprivileged container has no `/dev/net/tun`, so `tailscaled` can't make its interface and `sudo tailscale up` fails. Attaching through the printed SSH entry doesn't need Tailscale. Passing the host's `/dev/net/tun` in (`incus config device add dev tun unix-char path=/dev/net/tun`) is your call: the launcher adds no host devices.
- **The disk limit depends on the storage pool.** On a `btrfs`, `zfs` or `lvm` pool, the 40 GiB is enforced. On a `dir` pool, the `incus admin init --minimal` default, it is enforced only on ext4 or XFS with project quotas. Otherwise Incus skips it with only a warning in its own log, and the container can fill the host's disk. `incus storage list` shows the driver.
- **Memory:** `limits.memory` caps it, and `free` inside shows the limit, not the host's RAM.

### Startup, disk and RAM

`tests/vm/test_incus_provider.sh --container <name>` and `tests/vm/test_incus_provider.sh <name>` each end by printing the instance's disk and memory use once installed, and the time from `incus start` to an SSH login. Run both on one host to compare. **No run yet:** the container mode was written on a machine without Incus (2026-10-09), so it is tested only against a stub `incus`.

## Incus on another host (unverified)

Prefix the name with an Incus remote, set up with `incus remote add`:

```bash
scripts/providers/incus.sh far:dev --ssh-key laptop.pub --jump farhost
```

- Every Incus call goes to the remote: the image, the VM, the ACL and the install.
- `--jump` names that remote host as your laptop reaches it over SSH.
- The block names the VM `dev`, without the remote.
- This is tested only against a stub `incus`. No second Incus host was available.

## Colima on a Mac (unverified)

Untested, because there was no Mac. What should apply:
- **Nested virtualization:** Colima's Incus runtime (`colima start --runtime incus`) runs Incus inside a Linux VM, so an Incus VM there is a VM inside a VM. Colima's README says that needs Apple Silicon M3 or newer, and the flag differs between Colima versions.
- **The home share:** Colima mounts your home directory into its own VM by default, so start it with a narrower `--mount`. The launcher adds no disk devices, so that share never reaches the Incus VM, but it does reach Colima's VM.
- **The jump host:** reach the Colima VM with `colima ssh-config >> ~/.ssh/config`, then pass `--jump colima`.
- **The launcher needs bash 4 or newer** (macOS ships 3.2), plus `jq`.
- Whether Colima's Incus network is a managed bridge, which the ACL needs, is unverified.

## Known limits

- **The IP isn't pinned.** If the VM's address changes, SSH fails loudly on the host key, through `HostKeyAlias` and strict checking. Re-run the launcher to print the new address.
- **GitHub's API rate limit is shared.** The install fetches release data from GitHub's API. Without a token, GitHub allows 60 requests an hour per public IP, and every VM on one host reaches GitHub through the host's IP. Several installs in an hour can use it up. On 2026-10-09, a day of test installs from one host did, and the next install failed in its stack phase with 403s and "Failed to fetch version information". The launcher then keeps the VM as an unfinished install. `curl -s https://api.github.com/rate_limit` shows when the limit resets; re-run the launcher after that to resume.

## Tests

- `bash tests/unit/test_incus_provider_stub.sh`: the launcher's calls and output, against a stub `incus`.
- `tests/vm/test_incus_provider.sh [--container] <new-name>`: a real VM, or with `--container` a real container, checked through the printed block, then measured. It's opt-in and runs a full ACFS install, and it skips with the reason when Incus, KVM (for a VM) or `images:` isn't available.
