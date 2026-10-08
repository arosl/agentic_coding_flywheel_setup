# SSH Basics

**Goal:** Understand how to stay connected to your VPS.

---

## What Is SSH?

SSH (Secure Shell) is how you're connected to this VPS right now.

It's an encrypted tunnel between your laptop and this server.

---

## How You Got Here: The Two-Step Connect

Your VPS connection happened in two stages:

### Stage 1: Password Login (During Setup)
When you first created your VPS, you connected as root with a password:

```bash
ssh root@YOUR_SERVER_IP
```

This let you run the ACFS installer.

### Stage 2: Key-Based Login (Now)
The installer copied your SSH key, so now you connect securely:

```bash
ssh -i ~/.ssh/acfs_ed25519 ubuntu@YOUR_SERVER_IP
```

Breaking it down:
- `ssh` - the command
- `-i ~/.ssh/acfs_ed25519` - your private key (you created this on your laptop)
- `ubuntu` - your regular user account (safer than root)
- `@YOUR_SERVER_IP` - the server address

---

## If Your Connection Drops

No worries! SSH connections drop sometimes. Just reconnect:

1. On your laptop, run the ssh command again
2. Your work is safe in herdr (next lesson)

---

## SSH Keys vs Passwords

You're now using **key-based authentication**:
- Your **private key** stays on your laptop (`~/.ssh/acfs_ed25519`)
- Your **public key** is on the VPS (`~/.ssh/authorized_keys`)

This is more secure than passwords and lets you connect without typing anything.

**Why we started with a password:** VPS providers give you root access with a password. The installer then sets up key-based login, which is faster and more secure than typing passwords.

---

## Keeping Connections Alive

Add this to your laptop's `~/.ssh/config`:

```
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

This sends keepalive packets every 60 seconds.

---

## Quick Connect Alias

On your laptop, add to `~/.zshrc` or `~/.bashrc`:

```bash
alias vps='ssh -i ~/.ssh/acfs_ed25519 ubuntu@YOUR_SERVER_IP'
```

Then just type `vps` to connect!

---

## Verify You Understand

Answer these:
1. Where does your private key live? (`~/.ssh/acfs_ed25519` on your laptop)
2. What happens if SSH drops? (Reconnect; herdr keeps your work running)
3. What's the quick way to reconnect? (Use an alias)

---

## Practice This Now

Try these commands to confirm your SSH setup is working:

```bash
# Check your current user (should say "ubuntu")
whoami

# Check how long you've been connected
w

# View the public keys authorized to access this account
cat ~/.ssh/authorized_keys
```

When you see your public key (starts with `ssh-ed25519`), you know the setup worked!

---

## Next

This is why herdr is essential:

```bash
onboard 3
```
