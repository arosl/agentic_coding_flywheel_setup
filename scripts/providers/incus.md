# ACFS on an Incus VM

Run ACFS without renting a VPS. `scripts/providers/incus.sh` creates an Ubuntu VM with [Incus](https://linuxcontainers.org/incus/), installs ACFS inside it, and prints what the machine you work from needs to attach to it as a herdr remote machine.

The installer runs **inside the VM**, never on the machine that runs Incus.

---

## What you need

- **A Linux host with Incus and KVM.** The VM needs `/dev/kvm`, so check `incus info` works for you; on many hosts that means being in `incus-admin`. A fresh `incus admin init --minimal` is enough: the launcher uses the default profile, its storage pool and its managed bridge (`incusbr0`).
- **A clone of this repository on that host.** The launcher installs the clone's committed `HEAD`.
- **`git`, `jq` and `ssh-keygen` on that host.**
- **The public key of the machine you'll attach from,** usually your laptop's `~/.ssh/id_ed25519.pub`. Copy it to the host first. The host's own key is the wrong one when you attach from somewhere else.

## Create the VM

```bash
scripts/providers/incus.sh dev --ssh-key laptop.pub --jump myhost
```

- `dev` is the VM's name.
- `--jump myhost` is how your laptop reaches this host over SSH: a `Host` from your laptop's `~/.ssh/config`. Leave it out when you'll attach from the Incus host itself.
- **Time:** about half a minute until the VM has booted (a one-time check on 2026-10-09, with the image already cached), then the ACFS install. That install's length isn't measured yet: the only timed run, 604 s on 2026-10-09, stopped on a checksum failure that `main` has since fixed.
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
| exists, but its install never finished | starts it if it's stopped, and runs the installer again, which resumes where it stopped |
| is installed | starts it if it's stopped and prints the block again. **It never reinstalls.** Update ACFS inside the VM with `acfs update`. |
| wasn't created by this launcher | refuses to touch it |

- **How it decides:** the launcher records the installed commit on the instance (`user.acfs.installed`) only when the installer exits 0. ACFS's own `state.json` can list a failed install as complete, so the launcher doesn't read it.
- **If the install fails:** the VM is kept, and the block leaves out the `herdr machine add` line, because herdr may not be installed yet. Ignore the installer's own resume hint, which names a GitHub URL; re-run the launcher instead.
- **Uncommitted changes aren't installed.** The launcher archives the committed `HEAD`, through the installer's own `--bootstrap-archive` option, and warns when the checkout has changes it leaves out.
- **Stop or remove:** `incus stop dev`, or `incus delete dev`. The launcher never deletes anything.

## What reaches the VM

- **SSH keys:** only the public keys you pass with `--ssh-key`, for the `ubuntu` user. `--ssh-key` is ignored when the VM already exists; add keys later with `ssh-copy-id`.
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
- **The ACL is `acfs-vm-egress`.** It rejects outgoing traffic to `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` (CGNAT, which includes tailnets), `169.254.0.0/16` and `fc00::/7`.
- **Everything else passes,** including the internet, the bridge's DNS and DHCP, and the replies to your SSH sessions.
- **When it's created:** on the first run, if it doesn't exist. The launcher never changes an existing one.
- **Where it applies:** it's attached to each launcher VM's NIC (`security.acls`). Other instances aren't affected.
- **It needs a managed bridge.** On any other network, the launcher stops before creating the VM.
- **What it doesn't cover:** the host's addresses outside those ranges, such as a public IP, stay reachable from the VM. The host's sshd still needs a key the VM doesn't have.

## herdr versions

- **Nothing is pinned.** ACFS installs the latest herdr release into `~/.local/bin` in the VM, and the printed block names that version.
- **What herdr does about a version mismatch** (herdr v0.9.3, [Connecting machines](https://herdr.dev/docs/connecting-machines/) and [Remote attach](https://herdr.dev/docs/persistence-remote/)):
  - The client and the VM's server negotiate compatibility; their versions don't have to match.
  - If they aren't compatible, an interactive `herdr machine add dev`, or `herdr --remote dev`, offers to install the client's version on the VM. It asks before it stops a running server, and the default answer is No.
  - Background reconnects never install anything. They show **Attention** until you run that interactive setup.
  - Updating your laptop's herdr doesn't touch the VM's server. `acfs update` inside the VM updates the VM's herdr; the running server keeps its version until it restarts.
- **`~/.local/bin` isn't on the PATH of a non-interactive SSH command** in the VM. herdr's own discovery looks there, but a bare `ssh dev herdr` doesn't find it. Use `ssh dev .local/bin/herdr`.

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

## Tests

- `bash tests/unit/test_incus_provider_stub.sh`: the launcher's calls and output, against a stub `incus`.
- `tests/vm/test_incus_provider.sh <new-name>`: a real VM, checked through the printed block. It's opt-in and runs a full ACFS install, and it skips with the reason when Incus, KVM or `images:` isn't available.
