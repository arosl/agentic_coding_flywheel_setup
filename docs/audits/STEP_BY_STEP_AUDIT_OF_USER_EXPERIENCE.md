# Step-by-Step Audit of User Experience

> **Audit Date:** December 2024
> **Perspective:** Complete beginner with no Linux, SSH, or terminal experience
> **Goal:** Identify confusion points, missing steps, and areas for improvement

---

## Executive Summary

The Agent Flywheel setup process is remarkably comprehensive, with excellent beginner-friendly explanations through the `SimplerGuide` components and `Jargon` tooltips. However, several critical gaps exist that could leave beginners stranded, particularly around **SSH key placement**, **agent authentication**, and the crucial **"now what?"** moment after installation.

### Top 5 Critical Issues

1. **SSH Key Placement** - The wizard explains how to generate and copy an SSH key, but doesn't show WHERE to paste it in the VPS provider's interface
2. **Agent Authentication Gap** - Users are told to run `cc` but not that they must first authenticate with `claude` command
3. **Post-Installation Void** - After "Congratulations!", there's no clear first project walkthrough
4. **Reconnection Mystery** - If users close their laptop, they don't know how to get back to their work
5. **Overwhelming Account Setup** - 12+ services presented at once creates decision paralysis

---

## Phase 1: Landing Page Experience (agent-flywheel.com)

### What Works Well
- Clean, professional design with animated terminal demo
- Clear "10 Steps to Liftoff" workflow preview
- About section explains the creator and motivation
- Jargon tooltips help with unfamiliar terms

### Confusion Points

#### 1.1 Technical Overload
**Location:** Hero section and feature cards

The landing page uses many technical terms even with tooltips:
- "VPS", "curl", "agentic", "idempotent", "sudo", "zsh", "oh-my-zsh", "powerlevel10k", etc.

**User thought:** "I just want AI to help me code. Why do I need to learn about zsh and powerlevel10k?"

**Recommendation:** Add a prominent "Is this for me?" section:
```markdown
## Is This For You?

This is for you if:
- You want AI to write code for you, not just suggest snippets
- You're willing to invest ~$500/month in AI subscriptions
- You can follow step-by-step instructions (no coding experience needed!)

This is NOT for you if:
- You want a free solution (the AI subscriptions cost money)
- You only want to write code yourself with occasional AI help
- You're looking for a mobile-first solution
```

#### 1.2 Hidden Cost Reality
**Location:** Not prominently displayed on landing page

The full investment is buried in the rent-vps page's SimplerGuide:
- VPS: ~$56/month
- Claude Max: $200/month (or $400 for 2 accounts)
- ChatGPT Pro: $200/month

**Total: $456-656/month**

**User thought:** "Wait, this will cost me over $400 a month?! I thought it was just the VPS cost."

**Recommendation:** Add a "What Does This Cost?" section to the landing page with honest pricing before users invest time.

---

## Phase 2: Setup Wizard Deep Dive

### Step 1: OS Selection (/wizard/os-selection)

**Status:** Excellent

- Auto-detects user's OS from browser
- Clear explanation in SimplerGuide
- Simple Mac/Windows choice

**No issues identified.**

---

### Step 2: Install Terminal (/wizard/install-terminal)

**Status:** Good with minor gaps

**What works:**
- Direct download buttons for Mac (Ghostty.dmg)
- Step-by-step installation instructions
- Screenshots would help but not strictly necessary

**Confusion Point 2.1: Windows Microsoft Store Navigation**

New Windows users may not know how to use the Microsoft Store.

**Missing:** Explicit instruction to sign into Microsoft account if prompted.

**Recommendation:** Add:
> "If the Microsoft Store asks you to sign in, you can either sign in with a Microsoft account or click 'Skip' - both work fine."

---

### Step 3: Generate SSH Key (/wizard/generate-ssh-key)

**Status:** Very good, but one subtle issue

**What works:**
- Excellent explanation of what SSH keys are
- Privacy assurance that keys never leave the computer
- Step-by-step with copy buttons
- Troubleshooting section for common errors

**Confusion Point 3.1: "Press Enter twice" Ambiguity**

The instruction says:
> "Press Enter twice when asked for a passphrase (leave it empty for now)."

**User thought:** "Do I press Enter twice quickly? Or wait for each prompt?"

**Recommendation:** Change to:
> "When it asks 'Enter passphrase', don't type anything - just press Enter. When it asks again to confirm, press Enter again. Leaving it empty is fine for this use case."

**Confusion Point 3.2: "Keep your public key handy"**

Users are told to copy the key to a notes app, but they might:
- Forget to do this
- Close their terminal and lose access
- Not know where to find it again

**Recommendation:** Add a "Find it later" tip:
```markdown
**Can't find your key later?** Just run this command again to see it:
`cat ~/.ssh/acfs_ed25519.pub`
```

---

### Step 4: Rent a VPS (/wizard/rent-vps)

**Status:** Good but overwhelming

**What works:**
- Honest "no affiliate" disclaimer
- Detailed spec recommendations
- Explains why 64GB RAM matters
- Full cost breakdown in SimplerGuide

**Confusion Point 4.1: Decision Paralysis**

Two providers (Contabo, OVH) with multiple plans each. Beginners don't have mental models to compare.

**User thought:** "Which one should I actually pick? They both look the same to me."

**Recommendation:** Be more opinionated:
```markdown
## Our Recommendation: Just Get This

**Contabo Cloud VPS 50** (~$56/month, US datacenter)
- 64GB RAM, 16 vCPU, 250GB NVMe
- This is what we use. Don't overthink it.

[Order Contabo VPS 50 Now] (direct link to pre-configured order page if possible)
```

**Confusion Point 4.2: Account Creation Anxiety**

First-time VPS renters may worry about:
- Providing credit card details to unknown company
- Monthly commitment
- What happens if they stop paying

**Recommendation:** Add a "Commitment FAQ":
```markdown
**FAQ:**
- **Can I cancel anytime?** Yes, these are month-to-month. No contracts.
- **Is my credit card safe?** These are established companies. You can also use PayPal.
- **What if I stop paying?** Your VPS gets deleted. Always push code to GitHub as backup.
```

---

### Step 5: Create VPS (/wizard/create-vps)

**Status:** CRITICAL GAP - SSH Key Placement

**What works:**
- Checklist format
- Provider-specific guides exist

**CRITICAL Issue 5.1: WHERE do I paste my SSH key?**

The wizard says "Pasted my SSH public key" as a checklist item, but doesn't show:
- WHERE in the provider interface to find the SSH key section
- WHEN in the order process to add it
- WHAT the interface looks like

**User experience:**
1. User goes to Contabo
2. Starts creating VPS
3. Can't find where to add SSH key
4. Gives up or skips it
5. Later gets "Permission denied" error

**Recommendation:** Add provider-specific screenshots or very explicit instructions:

```markdown
### Adding Your SSH Key in Contabo

1. During the order process, look for **"Password & Login"** section
2. Select **"SSH Key"** instead of "Password"
3. Click **"Add SSH Key"**
4. In the popup, paste your ENTIRE public key (starts with `ssh-ed25519`)
5. Give it a name like "My Laptop"
6. Click **"Save"**

**Can't find it?** Some providers add SSH keys AFTER creating the VPS:
- Go to your VPS control panel
- Look for "Access" or "SSH Keys" section
- Add your key there
```

**Confusion Point 5.2: IP Address Location**

"Copied the IP address" - but WHERE is it shown?

**Recommendation:** Add:
```markdown
**Finding Your IP Address:**
- **Contabo:** Go to "Your services" > "VPS control" - IP is shown next to your VPS name
- **OVH:** Go to your VPS dashboard - IP is in the main panel
```

---

### Step 6: SSH Connect (/wizard/ssh-connect)

**Status:** Good with excellent troubleshooting

**What works:**
- Pre-filled SSH command with user's IP
- Ubuntu vs root fallback explained
- Comprehensive troubleshooting section
- "yes" prompt explanation

**Confusion Point 6.1: Scary Fingerprint Warning**

The first-time connection shows:
```
The authenticity of host 'xxx.xxx.xxx.xxx' can't be established.
ED25519 key fingerprint is SHA256:xxxxx...
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

**User thought:** "This looks like a security warning! Am I being hacked?"

The wizard mentions this but could be more reassuring.

**Recommendation:** Add explicit expectation-setting BEFORE they connect:
```markdown
**What you'll see (don't panic!):**

When you connect for the first time, you'll see a scary-looking message about
"authenticity" and a "fingerprint". This is NORMAL and expected!

It's your computer asking "Hey, I've never talked to this server before.
Are you sure it's the right one?" Just type `yes` and press Enter.
```

---

### Step 7: Set Up Accounts (/wizard/accounts)

**Status:** Overwhelming

**What works:**
- Categorized by purpose (Access, Agents, Cloud, DevTools)
- Priority badges (Strongly Recommended, Recommended, Optional)
- "Sign up with Google" shortcuts
- Post-install commands shown

**CRITICAL Issue 7.1: Information Overload**

12+ services presented simultaneously:
- GitHub, Anthropic, OpenAI, Google AI
- Cloudflare, Vercel, Supabase
- Various API keys

**User thought:** "Do I really need ALL of these? This is going to take hours!"

**Recommendation:** Split into phases:

```markdown
## Phase 1: Essential (do now)
- GitHub (you need this for code backup)
- Anthropic Claude Max (your main AI agent)

## Phase 2: After First Project (do later)
- OpenAI (for Codex CLI)
- Google AI (for Gemini CLI)

## Phase 3: When Deploying (do when needed)
- Vercel (for deploying web apps)
- Cloudflare (for domains)
- Supabase (for databases)
```

**Confusion Point 7.2: No Authentication Instructions**

Services are listed with signup links, but there's no instruction that after signup, users need to run authentication commands ON THE VPS.

**Missing connection:** After creating an Anthropic account, user must run `claude` on the VPS to authenticate. This is mentioned in the card as "Post-install: claude" but it's easy to miss and not explained.

**Recommendation:** Add explicit section:
```markdown
## After Signing Up: Authenticate on Your VPS

After creating accounts, you need to connect them to your VPS:

1. SSH into your VPS
2. Run the authentication command for each service:
   - Claude: Type `claude` and follow the browser login
   - GitHub: Type `gh auth login` and follow prompts
   - Vercel: Type `vercel login`
```

---

### Step 8: Run Installer (/wizard/run-installer)

**Status:** Good

**What works:**
- Single copy-paste command
- Time estimate (10-15 minutes)
- "What it installs" breakdown
- Transparency about open source

**Confusion Point 8.1: Long Wait with No Progress Indication**

Users are told to wait 10-15 minutes watching text scroll by.

**User thought:** "Is it stuck? Should I do something? When will this end?"

**Recommendation:** Add:
```markdown
**What to expect during installation:**
- Lines starting with `[1/8]`, `[2/8]`, etc. show overall progress
- You'll see lots of download progress bars
- Some steps compile code (Rust tools) - this takes a few minutes
- When you see "Installation complete!", you're done

**It's okay to:**
- Watch a video while you wait
- Keep this browser tab open for reference
- NOT touch the terminal (let it run)
```

---

### Step 9: Launch Onboarding (/wizard/launch-onboarding)

**Status:** CRITICAL GAP - "Now What?"

**What works:**
- Celebratory design with confetti
- Quick command reference (cc, herdr, rg, lazygit)
- Link to Learning Hub

**CRITICAL Issue 9.1: No First Project Walkthrough**

The page says "What you can do now" but doesn't provide a GUIDED first experience.

**User reality:**
1. User sees "Start Claude Code" with command `cc`
2. Types `cc`
3. Gets authentication prompt (wasn't expecting this!)
4. Completes auth
5. Claude opens but... now what?
6. What folder should they be in?
7. What should they ask Claude to do?

**Recommendation:** Add a "Your First 5 Minutes" section:

```markdown
## Your First 5 Minutes (Do This Now!)

Let's make sure everything works with a quick test:

### 1. Create a project folder
```bash
mkdir ~/hello-ai && cd ~/hello-ai
```

### 2. Start Claude Code
```bash
cc
```
If this is your first time, it will open a browser to log in. Complete the login.

### 3. Ask Claude to create something
In the Claude prompt, type:
> Create a simple Python script that prints "Hello from AI!" and run it

### 4. Watch the magic!
Claude will:
- Create a file called `hello.py`
- Write the code
- Run it for you

🎉 You just used AI to write and run code!
```

**CRITICAL Issue 9.2: Reconnection Not Explained**

If user closes their laptop or terminal, they'll be completely lost.

**Recommendation:** Add prominent section:

```markdown
## Closed Your Terminal? Here's How to Get Back

1. Open your terminal app
2. Reconnect to your VPS:
   ```bash
   ssh -i ~/.ssh/acfs_ed25519 ubuntu@YOUR_IP
   ```
3. Your work is still there! Your agents kept running in herdr:
   ```bash
   herdr
   ```
   This brings back your entire session exactly where you left off.

**Pro tip:** Bookmark the SSH command or save it as a shortcut!
```

---

## Phase 3: Post-Setup Learning Journey

### Learning Hub (/learn)

**Status:** Good structure, needs connecting to terminal experience

**What works:**
- 9 progressive lessons
- Progress tracking
- Quick reference links
- Locked lesson progression ensures order

**Issue 3.1: Web vs Terminal Disconnect**

The Learning Hub is a web experience, but users are learning terminal skills. There's a disconnect.

**User thought:** "I'm reading about tmux commands on my phone, but I can't practice them here."

**Recommendation:** Each lesson should end with:
```markdown
## Practice This Now

SSH into your VPS and try these commands:
1. [Command 1]
2. [Command 2]
3. [Command 3]

When you've successfully completed these, come back and click "Mark Complete".
```

### Lesson Content Review

#### Lesson 4: Agent Commands (04_agents_login.md)
**Critical:** This is where authentication is explained, but it comes AFTER the wizard's accounts page where users created accounts but weren't told to authenticate.

**Issue:** Timeline mismatch. User:
1. Creates Anthropic account (wizard step 7)
2. Runs installer (wizard step 8)
3. Reaches "Launch Onboarding" and tries `cc`
4. Gets confused by auth prompt
5. Eventually finds Lesson 4 which explains this

**Recommendation:** Either:
- Move authentication instructions to wizard step 7 (accounts)
- Add a "First: Authenticate" section to launch-onboarding page

---

## Specific User Journey Simulation

### Persona: Sarah, 45, Marketing Manager
- Has Windows laptop
- Never used terminal before
- Saw demo of AI coding, wants to try it
- Technical comfort level: 2/10

### Sarah's Journey (Annotated)

| Step | Sarah's Action | Sarah's Thought | Issue |
|------|----------------|-----------------|-------|
| 1 | Visits site | "Ooh pretty. What's a VPS?" | Tooltips help but still foreign |
| 2 | Clicks "Start the Wizard" | "OK let's try this" | Good |
| 3 | Selects Windows | "Yes that's me" | Auto-detect works |
| 4 | Downloads Windows Terminal | "Where's Microsoft Store?" | Minor confusion |
| 5 | Installs terminal | "That was easy" | Good |
| 6 | Runs ssh-keygen | "What's happening? It's asking for passphrase" | Follows instructions, works |
| 7 | Copies public key | "This weird text is my key?" | Follows instructions |
| 8 | Goes to Contabo | "Which plan? This is confusing" | Decision paralysis |
| 9 | **STUCK: Can't find where to add SSH key** | "WHERE do I put my key?!" | **CRITICAL** |
| 10 | Skips SSH key, creates with password | "I'll figure out the key thing later" | Common workaround |
| 11 | Gets VPS IP | "Got it" | Good |
| 12 | Tries SSH command | "Permission denied?! What?!" | Because SSH key wasn't added |
| 13 | Tries root instead | Still fails | SSH key problem |
| 14 | **GIVES UP** | "This is too hard" | **Lost user** |

### If Sarah HAD added SSH key correctly:

| Step | Sarah's Action | Sarah's Thought | Issue |
|------|----------------|-----------------|-------|
| 12 | SSH connects | "It's asking about fingerprint?" | Scary but documented |
| 13 | Types 'yes' | "OK I'm in!" | Good |
| 14 | Runs installer | "Lots of text scrolling by" | Normal |
| 15 | Waits 15 minutes | "Is it stuck?" | Anxiety but works |
| 16 | Sees "complete" | "Yay!" | Good |
| 17 | Clicks "I installed it" | "Now what?" | Unclear next steps |
| 18 | Tries `cc` | "It wants me to log in somehow" | Unexpected auth |
| 19 | **CONFUSED about browser auth from terminal** | "How does this work?" | Auth flow unclear |
| 20 | Eventually logs in | "OK Claude is running" | Works |
| 21 | **Doesn't know what to type** | "What do I even ask it?" | No guidance |
| 22 | Closes laptop | "I'll continue tomorrow" | Normal |
| 23 | **Next day: doesn't remember SSH command** | "How do I get back in?" | **LOST** |

---

## Recommendations Summary

### P0 (Critical - Fix Immediately)

1. **Add SSH key placement instructions with provider-specific details**
   - Location: /wizard/create-vps
   - Include: Screenshots or very explicit UI navigation

2. **Add "Your First 5 Minutes" guided walkthrough**
   - Location: /wizard/launch-onboarding
   - Include: Create folder, start Claude, first prompt

3. **Add reconnection instructions prominently**
   - Location: /wizard/launch-onboarding AND browser bookmark prompt
   - Include: Full SSH command, then `herdr` to reattach

4. **Add authentication flow to wizard**
   - Location: Either /wizard/accounts or /wizard/launch-onboarding
   - Include: `claude`, `gh auth login` with what to expect

### P1 (Important - Fix Soon)

5. **Add upfront cost transparency**
   - Location: Landing page
   - Include: Full monthly investment breakdown

6. **Simplify accounts page**
   - Split into "Essential Now" vs "Do Later"
   - Reduce cognitive load

7. **Add expected output during installer**
   - Location: /wizard/run-installer
   - Include: What progress looks like, what "stuck" looks like

8. **Be more opinionated about VPS choice**
   - Location: /wizard/rent-vps
   - Include: "Just get this" single recommendation

### P2 (Nice to Have)

9. **Add video walkthroughs for each wizard step**
   - 2-3 minute screencasts
   - Especially for SSH key and first connection

10. **Add "Practice this now" sections to lessons**
    - Bridge web learning to terminal practice

11. **Add SSH command bookmarking feature**
    - Save to browser bookmarks or provide desktop shortcut script

12. **Add "stuck?" chat/help option**
    - Even just a Discord link would help

---

## Appendix: Full Wizard Step Audit

| Step | Page | Status | Major Issues |
|------|------|--------|--------------|
| 1 | OS Selection | Excellent | None |
| 2 | Install Terminal | Good | Minor Windows help needed |
| 3 | Generate SSH Key | Very Good | Passphrase prompt clarity |
| 4 | Rent VPS | Good | Decision paralysis |
| 5 | Create VPS | **CRITICAL** | SSH key placement missing |
| 6 | SSH Connect | Good | Fingerprint anxiety |
| 7 | Accounts | Overwhelming | Too many services at once |
| 8 | Preflight Check | Good | N/A |
| 9 | Run Installer | Good | Progress anxiety |
| 10 | Status Check | Good | N/A |
| 11 | Reconnect | Good | N/A |
| 12 | Launch Onboarding | **CRITICAL** | "Now what?" void |

---

## Conclusion

The Agent Flywheel project has done exceptional work making a complex multi-step process accessible to beginners. The `SimplerGuide` components, `Jargon` tooltips, and detailed step-by-step instructions are excellent.

The critical gaps are around the **transitions** between steps:
- Creating SSH key → WHERE to put it in provider
- Account creation → HOW to authenticate on VPS
- Installation complete → WHAT to do first
- Closing terminal → HOW to get back

Fixing these transition points would dramatically improve the completion rate for non-technical users.

---

*Audit prepared by AI assistant simulating beginner user perspective*
*December 2024*
