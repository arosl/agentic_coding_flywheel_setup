# SRPS: System Resource Protection Script

**Goal:** Keep your workstation responsive under heavy agent load.

---

## Why SRPS Matters

When AI coding agents run cargo build, npm install, or spawn multiple parallel processes, your system can become unresponsive. SRPS automatically manages process priorities so your terminal and IDE stay snappy while heavy work runs in the background.

---

## How It Works

SRPS installs two components:

1. **ananicy-cpp** - A daemon with 1700+ rules that auto-deprioritizes resource-intensive processes
2. **sysmoni** - A Go TUI for real-time monitoring of process priorities

---

## Essential Commands

### Check Status

```bash
systemctl status ananicy-cpp
```

### Monitor in Real-Time

```bash
sysmoni
```

### View Active Rules

```bash
ls /etc/ananicy.d/
```

---

## What Gets Managed

SRPS automatically deprioritizes:

- **Compilers**: rustc, gcc, clang, tsc, swc
- **Bundlers**: webpack, esbuild, vite, rollup
- **Test runners**: cargo test, jest, pytest
- **Browsers**: Chrome, Firefox, Electron apps
- **IDEs**: VS Code, JetBrains, neovim language servers

While keeping high priority:
- Your terminal emulator
- tmux/screen sessions
- Input handling

---

## Adding Custom Rules

Create a rule for any process:

```bash
# /etc/ananicy.d/my-rules.rules
{ "name": "myapp", "type": "BG_CPUIO" }
```

Rule types:
- `BG_CPUIO` - Background CPU/IO intensive
- `Heavy` - Very low priority
- `LowLatency_RT` - Real-time priority

---

## Integration with Other Tools

- **herdr**: SRPS keeps your agent panes responsive when agents spawn heavy builds
- **DCG**: Combined safety - DCG prevents destructive commands, SRPS prevents resource exhaustion
- **SLB**: When SLB launches multiple agents, SRPS prevents them from starving each other

---

## Quick Reference

| Command | What it does |
|---------|--------------|
| `systemctl status ananicy-cpp` | Check daemon status |
| `sysmoni` | Real-time process monitoring |
| `ls /etc/ananicy.d/` | List active rule files |
| `journalctl -u ananicy-cpp` | View daemon logs |

---

## Troubleshooting

**System still freezing?**
- Check if ananicy-cpp is running: `systemctl status ananicy-cpp`
- Restart the daemon: `sudo systemctl restart ananicy-cpp`

**Need to disable temporarily?**
```bash
sudo systemctl stop ananicy-cpp
```

**Re-enable:**
```bash
sudo systemctl start ananicy-cpp
```

---

## Next Steps

Now that SRPS is keeping your system responsive, you can safely:
- Run multiple agents in parallel in herdr
- Launch heavy builds without worrying about freezes
- Focus on your work while background tasks complete

---

*Run `sysmoni` during your next multi-agent session to see SRPS in action!*
