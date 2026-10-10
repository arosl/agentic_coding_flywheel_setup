# Step-by-Step Audit of User Experience - Round 2

**Perspective:** Complete beginner who has never used Linux, SSH, command line, or terminal programs, but wants to use AI coding agents to build software.

**Date:** 2025-12-22

---

## Overview

This audit traces through the entire user journey from visiting agent-flywheel.com through successfully using the system. I'm documenting confusion points, missing explanations, assumed knowledge, and recommended changes.

---

## Phase 1: Discovery & Initial Website Visit

### What Works Well
- Clear value proposition on homepage
- Wizard structure is logically organized
- Privacy reassurance about data staying local is prominent

### Issues & Recommendations

**Issue 1.1: No explanation of WHY a VPS**
- **Where:** Homepage and wizard introduction
- **Problem:** Users jumping in don't understand why they need to rent a cloud server. They might think "can't I just run this on my laptop?"
- **Fix:** Add a "Why VPS?" section explaining:
  - AI agents work best with persistent sessions
  - Avoid draining your laptop battery
  - Work continues even when your laptop is closed
  - Same environment from any device

**Issue 1.2: No cost expectations upfront**
- **Where:** Before VPS selection
- **Problem:** Users might be hesitant to proceed not knowing the ongoing cost
- **Fix:** Add "Expect $5-60/month depending on VPS choice" prominently early in the journey

---

## Phase 2: OS Selection (Step 1)

### What Works Well
- Simple binary choice (Mac/Windows)
- Clean UI with clear selection

### Issues & Recommendations

**Issue 2.1: No Linux option**
- **Where:** OS selection page
- **Problem:** Some users might already be on Linux and wonder what to do
- **Fix:** Add note: "Already on Linux? Skip to [SSH section]"

---

## Phase 3: Install Terminal (Step 2)

### What Works Well
- Good explanation of what a terminal is
- Clear download links for Ghostty/WezTerm/Windows Terminal

### Issues & Recommendations

**Issue 3.1: CRITICAL - No explanation of how to actually USE the terminal once installed**
- **Where:** Install terminal page
- **Problem:** User downloads and installs Ghostty. Then what? They open it and see a blank screen with a blinking cursor. They have NO IDEA what to do.
- **Fix:** Add a "Your First Terminal Commands" mini-tutorial:
  - Explain the prompt (the `$` or `%` symbol)
  - Show them that they type after the prompt
  - Have them type `echo "Hello"` and press Enter
  - Explain that the terminal responds

**Issue 3.2: No explanation of copy/paste in terminal**
- **Where:** Install terminal page
- **Problem:** Terminal copy/paste is different from regular apps. Users will try Ctrl+C and get confused (or worse, interrupt commands)
- **Fix:** Add clear instructions:
  - Mac: `Cmd+C`/`Cmd+V` work normally
  - Windows Terminal: Right-click to paste, or `Ctrl+Shift+C/V`

**Issue 3.3: No verification that terminal works**
- **Where:** Install terminal page
- **Problem:** No way to know if terminal is correctly installed
- **Fix:** Add verification: "Type `echo hello` and press Enter. You should see `hello` appear."

---

## Phase 4: Generate SSH Key (Step 3)

### What Works Well
- Good explanation of what SSH keys are (like a password but safer)
- Clear command to copy/paste

### Issues & Recommendations

**Issue 4.1: CRITICAL - Key saving location not explained for beginners**
- **Where:** After running ssh-keygen
- **Problem:** User runs the command, it asks "Enter file in which to save the key". They have NO IDEA what to type. Do they press Enter? Do they type something?
- **Fix:** Explicitly say: "Just press Enter to accept the default location. Don't type anything."

**Issue 4.2: CRITICAL - Passphrase confusion**
- **Where:** ssh-keygen prompts
- **Problem:** After the file location, it asks "Enter passphrase". Users will think they NEED to create a password. If they do, they'll be asked for it every SSH connection and forget it.
- **Fix:** Explicitly say: "When it asks for a passphrase, just press Enter twice (leave it empty). This is fine for your use case."

**Issue 4.3: No feedback on success**
- **Where:** After key generation
- **Problem:** User runs the command, sees output, but doesn't know if it worked
- **Fix:** Add: "You'll see an ASCII art randomart image. That means it worked!"

**Issue 4.4: What is ~/.ssh? Where is it?**
- **Where:** Key generation page
- **Problem:** `~/.ssh` is completely foreign to beginners
- **Fix:** Explain: "`~` means your home folder. `~/.ssh` is a hidden folder called `.ssh` in your home folder. Files starting with `.` are hidden in Unix systems."

---

## Phase 5: Rent a VPS (Step 4)

### What Works Well
- Good comparison of providers
- Price expectations set

### Issues & Recommendations

**Issue 5.1: No credit card warning**
- **Where:** VPS signup
- **Problem:** Users might not realize they need a credit card to sign up
- **Fix:** Add: "You'll need a credit card to sign up. Most providers offer hourly billing so you only pay for what you use."

**Issue 5.2: No email verification warning**
- **Where:** VPS signup
- **Problem:** Some providers require email verification and it can take time
- **Fix:** Add: "Check your email for verification. This can take a few minutes."

**Issue 5.3: Provider account vs VPS instance confusion**
- **Where:** Between rent-vps and create-vps steps
- **Problem:** The wizard has "Rent VPS" and "Create VPS" as separate steps, which is confusing. Beginners don't understand the difference between "signing up for an account" and "launching a server"
- **Fix:** Clarify: "First you create an account with the provider, then you launch your actual server"

---

## Phase 6: Create VPS Instance (Step 5)

### What Works Well
- Good checklist format
- Provider-specific guides are helpful

### Issues & Recommendations

**Issue 6.1: CRITICAL - "Ubuntu 24.04+ (25.10 preferred)" is meaningless**
- **Where:** Checklist
- **Problem:** Beginners don't know what Ubuntu is, what 24.04 means, or why 25.10 is preferred
- **Fix:** Add jargon tooltip: "Ubuntu is a version of Linux. The numbers are version numbers (like iPhone 15). Pick the highest number available."

**Issue 6.2: RAM requirements not explained**
- **Where:** VPS sizing
- **Problem:** "16GB RAM" means nothing to someone who doesn't understand computer specs
- **Fix:** Add: "RAM is like your computer's short-term memory. More RAM = more AI agents can run at once. 8GB is the minimum, 16GB is comfortable."

**Issue 6.3: IP Address format not shown clearly**
- **Where:** IP input field
- **Problem:** Placeholder shows `192.168.1.100` but real VPS IPs are public (like `45.67.123.89`). Users might think their VPS IP should look like the placeholder.
- **Fix:** Use a more realistic example: `45.123.67.89`

**Issue 6.4: CRITICAL - "Region closest to me" for better speed
- **Where:** Region selection guidance
- **Problem:** Users might not understand why region matters
- **Fix:** Explain: "Closer = faster response times. If you're in California, pick US-West. If in London, pick EU."

---

## Phase 7: SSH Into Your VPS (Step 6)

### What Works Well
- Clear command to copy
- Good troubleshooting section
- Explains "password won't appear as you type"

### Issues & Recommendations

**Issue 7.1: CRITICAL - "Type yes" confusion**
- **Where:** First SSH connection
- **Problem:** The host authenticity message is TERRIFYING to beginners. It looks like a security warning. They might be afraid to type "yes".
- **Fix:** More reassurance: "This message looks scary but it's NORMAL. It's your computer saying 'I've never seen this VPS before, do you trust it?' Type `yes` to say 'Yes, I trust it.'"

**Issue 7.2: CRITICAL - Password not working**
- **Where:** SSH password prompt
- **Problem:** Users often confuse their VPS provider account password with the VPS root password. These are DIFFERENT passwords.
- **Fix:** Emphasize: "The password here is the ROOT PASSWORD you set when creating the VPS, NOT your Contabo/Hetzner account password."

**Issue 7.3: "root@vps:~#" prompt not explained
- **Where:** Success state
- **Problem:** User successfully connects, sees `root@vps:~#`, has no idea what this means or what to do next
- **Fix:** The SimplerGuide section does explain this, but it's collapsed. Consider showing the prompt explanation prominently.

**Issue 7.4: How do I know I'm "inside" the VPS?**
- **Where:** After connection
- **Problem:** Mental model confusion - beginners don't viscerally understand that they're now controlling a remote computer
- **Fix:** Add: "Everything you type now runs on the VPS, not your laptop. Try `hostname` - you'll see the VPS name, not your laptop's name."

---

## Phase 8: Set Up Accounts (Step 7)

### What Works Well
- Tiered approach (Essential/Recommended/Optional)
- Google SSO option prominently featured
- Progress indicator

### Issues & Recommendations

**Issue 8.1: Too many accounts at once**
- **Where:** Accounts page
- **Problem:** Even with tiers, seeing 8+ services is overwhelming
- **Fix:** Make it clearer that ONLY Essential tier is needed now. Maybe collapse Recommended/Optional by default.

**Issue 8.2: Claude subscription confusion**
- **Where:** Claude Code signup
- **Problem:** Users might not realize they need a Claude Pro subscription ($20/month) to use Claude Code effectively
- **Fix:** Add: "Free tier has limits. Claude Pro ($20/month) is recommended for serious use."

**Issue 8.3: Codex requires ChatGPT Pro**
- **Where:** Codex CLI
- **Problem:** This is mentioned but might be missed. Users could sign up for OpenAI and then be unable to use Codex.
- **Fix:** More prominent warning: "Requires ChatGPT Pro subscription ($20/month)"

**Issue 8.4: What happens if I skip?**
- **Where:** Skip button
- **Problem:** Users might worry they'll be stuck if they skip account setup
- **Fix:** Add: "You can create these accounts anytime. The tools will prompt you when needed."

---

## Phase 9: Pre-Flight Check (Step 8)

*This step exists in the wizard flow but I didn't see a page for it - may need to verify*

---

## Phase 10: Run Installer (Step 9)

### What Works Well
- Clear command to copy
- "What it installs" expandable section
- Time estimate (10-15 minutes)

### Issues & Recommendations

**Issue 10.1: CRITICAL - No warning about SSH disconnection**
- **Where:** During installation
- **Problem:** If SSH disconnects during installation (common on home WiFi), users will panic. They'll think they broke something.
- **Fix:** Add prominent warning: "If your connection drops, just SSH back in. The installer will resume where it left off."

**Issue 10.2: CRITICAL - User watching scrolling text has no idea what's happening**
- **Where:** Installation output
- **Problem:** Lots of text flying by. User doesn't know if it's working, failing, or what any of it means.
- **Fix:** Add: "You'll see lots of text scrolling. Green checkmarks = good. Red X = something failed but installer will retry. Just wait for the 'Installation complete' message."

**Issue 10.3: "curl -fsSL" not explained**
- **Where:** Install command
- **Problem:** This command looks like gibberish to beginners
- **Fix:** Add tooltip or explanation: "`curl` downloads from the internet. `-fsSL` means 'do it quietly and follow redirects'. `| bash` means 'run what you downloaded'."

**Issue 10.4: Security concern - piping curl to bash**
- **Where:** Install command
- **Problem:** Security-aware users might be concerned about running random code from the internet
- **Fix:** The "View install.sh source" link is good, but could be more prominent. Maybe: "Want to see what you're running first? [View the full script here]"

---

## Phase 11: Reconnect as Ubuntu (Step 10)

### What Works Well
- "Already connected as ubuntu?" shortcut
- Clear exit/reconnect flow

### Issues & Recommendations

**Issue 11.1: CRITICAL - New SSH command is different**
- **Where:** Reconnect command
- **Problem:** The reconnect command uses `-i ~/.ssh/acfs_ed25519` which is NEW. User has to understand they're now using their key instead of password.
- **Fix:** Explain: "Notice this command is different - we're now using your SSH key (the one you generated earlier) instead of a password. You won't be asked for a password this time."

**Issue 11.2: What if key doesn't work?**
- **Where:** Reconnect step
- **Problem:** If key authentication fails, user is stuck
- **Fix:** Add troubleshooting: "If you get 'Permission denied', try the password method from before, then run the installer again."

**Issue 11.3: Powerlevel10k configuration wizard might appear**
- **Where:** First zsh login
- **Problem:** When they reconnect, powerlevel10k might prompt them to configure the prompt. This is unexpected and confusing.
- **Fix:** Add: "You might see a prompt customization wizard. Just press `q` to quit it for now - you can configure it later with `p10k configure`."

---

## Phase 12: Verify Key Connection (Step 11)

### Issues & Recommendations

**Issue 12.1: What am I verifying?**
- **Where:** Verify key connection page
- **Problem:** User might not understand what they're checking
- **Fix:** Clarify: "This confirms that your SSH key was installed correctly and you can connect without a password."

---

## Phase 13: Status Check (Step 12)

### What Works Well
- `acfs doctor` command is helpful
- Expected output shown
- Service authentication commands listed

### Issues & Recommendations

**Issue 13.1: CRITICAL - Auth commands don't work for headless VPS**
- **Where:** Service authentication (e.g., `claude`)
- **Problem:** When you run `claude` on a headless VPS, it tries to open a browser. But there's no browser on a VPS! The user will see a URL they need to open on their local machine.
- **Fix:** Explain CLEARLY: "The command will print a URL. Copy that URL and paste it into your browser on your laptop. Complete the login there, then return to the terminal."

**Issue 13.2: Browser URL opens on VPS, not laptop**
- **Where:** Any auth command
- **Problem:** If xdg-open or similar is installed, it might try to open a browser on the VPS, which fails silently
- **Fix:** Explain: "Ignore any 'browser not found' errors. Just copy the URL and paste it in your laptop's browser."

**Issue 13.3: Too many auth steps**
- **Where:** All auth commands
- **Problem:** User has to run auth for potentially 6+ services. This is exhausting.
- **Fix:** Emphasize that only Essential services need auth NOW. Others can wait.

---

## Phase 14: Launch Onboarding (Step 13)

### What Works Well
- Confetti celebration!
- "Your First 5 Minutes" quick start
- Getting Back In section

### Issues & Recommendations

**Issue 14.1: CRITICAL - `cc` command assumes auth already done**
- **Where:** "Your First 5 Minutes" section
- **Problem:** Step says "Run `cc`" but if Claude isn't authenticated, this will fail or prompt for auth
- **Fix:** Either: (a) make Step 2 "Authenticate Claude" more prominent, or (b) have step 3 be "Start Claude Code - if prompted, complete the browser login"

**Issue 14.2: Project folder location not explained**
- **Where:** `mkdir ~/my-first-project`
- **Problem:** User might not understand `~` or why they need to create a folder
- **Fix:** Explain: "`~` is your home folder. Creating a project folder helps organize your code."

**Issue 14.3: What if I close my laptop?**
- **Where:** Getting Back In section
- **Problem:** Users need reassurance that their work persists
- **Fix:** Add: "Your VPS keeps running even when your laptop is closed. All your work is saved on the VPS."

---

## Phase 15: Post-Wizard - Using the System

### Issues & Recommendations

**Issue 15.1: CRITICAL - No explanation of daily workflow**
- **Where:** After wizard completion
- **Problem:** User has no idea what their day-to-day routine should look like
- **Fix:** Add a "Your Daily Workflow" section:
  1. Open terminal
  2. SSH to VPS
  3. Run `herdr` to get your workspaces back
  4. `acfs agents list` shows each agent and its state
  5. Continue working with `cc`

**Issue 15.2: What is a herdr workspace? Why do I need it?**
- **Where:** herdr commands
- **Problem:** Users don't understand why they can't just SSH in and start typing
- **Fix:** Explain the "engine room" metaphor more: "herdr is like having multiple desktops on your VPS. Each workspace persists even if your SSH connection drops, and herdr shows what each agent in it is doing."

**Issue 15.3: How do I create a new project?**
- **Where:** Post-wizard
- **Problem:** User finished the wizard, now what? How do they start their OWN project?
- **Fix:** Add a "Starting Your First Real Project" guide:
  1. Create a workspace: `herdr workspace create --cwd ~/myproject`
  2. Clone or init repo
  3. Start Claude: `cc`
  4. Describe what you want to build

**Issue 15.4: Where are my files?**
- **Where:** Post-wizard
- **Problem:** Users might not understand the filesystem or where their code lives
- **Fix:** Explain: "Your code lives on the VPS at `/home/ubuntu/your-project-name`. You can browse with `lsd` (our fancy `ls`), navigate with `cd`, and search with `rg`."

**Issue 15.5: How do I edit files manually?**
- **Where:** Post-wizard
- **Problem:** Sometimes Claude gets things wrong and users need to manually edit
- **Fix:** Mention that they can use `nano filename` for simple edits, or that Claude can help them install VS Code Remote SSH for GUI editing

---

## Summary of CRITICAL Issues

### Must Fix Before Launch
1. **Terminal basics not taught** - Users don't know how to use a terminal after installing one
2. **SSH key passphrase confusion** - Users will set passphrases they forget
3. **SSH "type yes" is scary** - Needs more reassurance
4. **Root password vs account password confusion** - Very common mistake
5. **Auth commands on headless VPS** - Browser URL handling not explained
6. **Daily workflow not explained** - Users don't know what to do after wizard

### High Priority
1. Why VPS? Not explained upfront
2. Cost expectations missing
3. Password not appearing while typing - mentioned but needs emphasis
4. SSH disconnection during install - panic scenario not addressed
5. Powerlevel10k wizard appearing unexpectedly
6. herdr conceptual understanding missing

### Medium Priority
1. Provider account vs VPS instance confusion
2. RAM/Ubuntu version jargon
3. Too many accounts shown at once
4. Claude Pro requirement not prominent enough

---

## Recommended New Content to Create

1. **"Terminal Basics for Complete Beginners" lesson** - Before SSH key generation
2. **"Understanding VPS" explainer** - Before VPS selection
3. **"Your Daily Workflow" guide** - After wizard completion
4. **"Troubleshooting Common Issues" page** - Accessible throughout
5. **"Glossary of Terms"** - Expandable jargon definitions throughout

---

## Jargon Needing Better Tooltips

- VPS
- SSH
- Terminal
- Command line
- Root / sudo
- tmux
- Session
- Repository / Repo
- Git
- API key
- Environment variable
- Port
- IP address
- Ubuntu
- zsh
- Bash

---

## Testing Recommendations

1. **Recruit 3-5 actual beginners** to go through the wizard while screen-sharing
2. **Record their confusion points** and frustrations
3. **Time each step** to see where people get stuck
4. **Track drop-off points** with analytics (already partially implemented)

---

*Audit completed by Claude (Opus 4.5) in ACFS code review session.*
