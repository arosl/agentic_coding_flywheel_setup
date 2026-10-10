# The Flywheel Core Loop

> A beginner-friendly version of the Flywheel methodology built around the three tools that carry most of the practical value.

This document exists because the full Flywheel system has grown large enough that many people find it overwhelming on first contact. That reaction makes sense. The larger system includes planning workflows, memory systems, prompt libraries, launch tooling, safety tooling, skills, and a lot of accumulated operational detail.

But there is a much smaller core that already captures most of what makes the approach powerful.

That core uses just three tools:

- [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) for multi-agent coordination and communication
- [`br`](https://github.com/Dicklesworthstone/beads_rust) for dependency-aware task management
- [`bv`](https://github.com/Dicklesworthstone/beads_viewer) for graph-aware triage so agents keep choosing the highest-leverage next bead

If you understand those three and use them together correctly, you already have the heart of the system.

These are the core **operating** tools, not the only ingredients in the whole process. The first step is still the same as in the larger methodology: create an excellent markdown plan by combining input from multiple frontier models, including website-only models like GPT Pro when they are helpful. The smaller core loop means a minimal persistent toolchain. It does not excuse weak planning.

Separate the process into two layers:

- the **planning substrate**: frontier models, especially strong web-app models, used to create and refine the markdown plan
- the **core operating loop**: [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail), [`br`](https://github.com/Dicklesworthstone/beads_rust), and [`bv`](https://github.com/Dicklesworthstone/beads_viewer) once the plan is ready to drive execution

So when this guide says "three-tool core," it means the durable execution substrate you keep live while the project is being carried out. It does not mean the planning phase happens in a vacuum.

In practical terms, the first hour usually looks like this: use frontier models to create the plan, use [`br`](https://github.com/Dicklesworthstone/beads_rust) to encode the first beads, use [`bv`](https://github.com/Dicklesworthstone/beads_viewer) to decide where execution should start, and use [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) as soon as more than one agent is live. The planning substrate gets you to a good plan; the three-tool core keeps execution coherent after that.

## Tool Boundary

| Layer | What it is for |
|------|-----------------|
| frontier models | generating and refining the markdown plan |
| [`br`](https://github.com/Dicklesworthstone/beads_rust) | turning that plan into explicit task structure |
| [`bv`](https://github.com/Dicklesworthstone/beads_viewer) | routing work through the dependency graph |
| [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) | coordinating claims, reservations, progress, and handoff |

Newcomers often blur the tools together. The planning models produce the design artifact. `br` encodes the work. `bv` tells the swarm what matters next. Agent Mail keeps the humans and agents from colliding while that work happens.

## Example Legend

This guide uses three kinds of examples:

- **Conceptual example**: a made-up project such as Atlas Notes, used to explain the workflow cleanly
- **Generic stand-in**: placeholders such as `br-123`, used to show conventions without depending on one workspace
- **Real live tool capture**: output copied from an actual workspace, such as `bd-ljd1`, used to show what the tools really emit

If you keep that legend in mind, the later shifts between examples make a lot more sense.

## Who This Is For

This document is for a relatively smart software developer who is new to agentic coding and does not want to absorb the entire larger Flywheel guide up front.

The goal is narrower: get you to the point where you can:

- coordinate multiple agents without chaos
- keep work organized as explicit tasks with dependencies
- keep agents working on the best next unblocked task instead of choosing randomly

If that works well for you, the larger Flywheel stack becomes much easier to appreciate later.

## You Are Here

If you want the shortest useful reading path:

1. read [Tool Boundary](#tool-boundary), [Five Terms You Need Before Continuing](#five-terms-you-need-before-continuing), and [The Core Idea](#the-core-idea)
2. read the example cluster: [One Concrete Example](#one-concrete-example), [Sample Artifact Packet](#sample-artifact-packet), [Annotated First Run](#annotated-first-run), and [Literal First Session Transcript](#literal-first-session-transcript)
3. try one tiny real run
4. come back for [Common Failure Modes](#common-failure-modes) and the [Appendix: Cheat Card](#appendix-cheat-card)

That path gets you oriented first, operational second, and diagnostic third.

## Five Terms You Need Before Continuing

| Term | Meaning |
|------|---------|
| `bead` | A self-contained task with enough context, dependency information, and completion criteria that an agent can work it without guessing. |
| `ready bead` | A bead whose blockers are cleared, so it can be started right now. |
| `claim` | The act of announcing, usually in Agent Mail, that a specific agent is taking responsibility for a bead. |
| `reservation` | A coordination lock or lease on files or resources so two agents do not unknowingly collide. |
| `thread` | The running Agent Mail conversation tied to one bead ID, where start, progress, review, and completion messages accumulate. |

If those five terms stay clear in your head, most of the rest of the guide gets much easier to follow.

## The Core Idea

The core loop is simple:

1. Generate and refine a serious markdown plan using multiple frontier models.
2. Convert that plan into beads with dependencies.
3. Let agents coordinate through Agent Mail while `bv` keeps routing them toward the best next bead.
4. Repeat until the graph is done.

Those four steps are the loop.

### Normal Chat Coding vs. The Core Loop

| Normal chat coding | The core loop |
|--------------------|---------------|
| The task mostly lives in chat | The task gets formalized into a markdown plan and then beads |
| Coordination lives in chat scrollback or in the human's head | Coordination is externalized through Agent Mail |
| Agents pick work based on local convenience or whatever they last saw | `bv` routes work from the dependency graph |
| Progress is hard to inspect later | The bead graph and message threads form a durable record |
| A crashed agent often takes its local state with it | Another agent can resume from the bead and the thread |

The table gives the short answer to "why bother?" The core loop moves work out of ephemeral chat and into explicit, inspectable artifacts.

## One Concrete Example

A small project makes the workflow easier to picture.

Imagine you want to build an internal tool called **Atlas Notes**:

- team members upload Markdown notes
- the system tags and indexes them
- users can search them quickly
- admins can inspect failed ingestions

If you gave four agents only that vague description, they would likely step on each other and make mismatched assumptions.

The core loop would instead look like this:

1. You ask multiple frontier models to produce competing markdown plans, then synthesize them into one strong plan describing uploads, parsing, tagging, search, admin review, and testing expectations.
2. You convert that synthesized plan into beads in `br`, for example:
   - `br-101`: upload and parse pipeline
   - `br-102`: indexing and search
   - `br-103`: failed-ingestion admin screen
   - `br-104`: auth and permissions
   - `br-105`: end-to-end tests
3. You add dependencies so the graph reflects reality.
4. Agents use Agent Mail to announce claims and reserve files.
5. Agents use `bv` to see which ready bead matters most right now.
6. They work, update bead status, send progress in-thread, and repeat.

Those six steps are enough to get a real swarm workflow running without the rest of the Flywheel stack.

## Sample Artifact Packet

The fastest way to make the workflow feel real is to look at a tiny packet of artifacts from the same imaginary project.

### Sample Markdown Plan Excerpt

```markdown
# Atlas Notes Plan Excerpt

- Users upload Markdown notes through a drag-and-drop interface.
- The system parses frontmatter tags, title, date, and body content.
- Parse failures must be preserved for later review rather than discarded.
- Search must support keyword, tag, and date filtering.
- Search should feel fast enough that the user perceives it as instant.
- Admins need a failure-review screen with parse error details and retry actions.
- Auth is internal-only; unauthorized users must never see note content or metadata.
- The upload flow needs explicit user feedback for success, partial success, and failure.
- We need unit coverage for parsing and indexing logic.
- We need end-to-end coverage for upload, failure review, search, and filtering.
- The admin review screen should expose enough detail to debug malformed inputs.
- The first version should optimize for correctness and operator visibility, not speculative scale.
```

### Sample Bead

```markdown
br-103: Failed-ingestion admin screen

Context:
The markdown plan requires failed uploads to be preserved and reviewable by internal admins. Right now we have a conceptual failure bucket but no usable interface for inspecting it.

Task:
Build the first admin screen for failed ingestions. It should list failed uploads, show parse error details, surface the original filename and timestamp, and allow an admin to retry ingestion after inspection.

Why this matters:
Without this screen, failed uploads effectively disappear into a black hole. That makes the product feel flaky and removes the operator visibility promised in the plan.

Depends on:
- br-101 upload + parse pipeline
- br-104 auth and permissions

Definition of done:
- Failed ingestions are queryable in the admin UI
- Each row shows filename, failure reason, and creation time
- Admin can open a details view for a specific failure
- Admin can trigger a retry action
- Unauthorized users cannot access this surface

Tests:
- Unit tests for failure-record formatting / mapping
- E2E test covering a malformed upload, admin inspection, and retry flow

Likely touch points:
- admin failure-review route
- failure-details component
- retry action / handler

Coordination note:
- announce the claim in thread br-103 before touching admin UI files
```

### Human Summary of a Typical `bv` Recommendation

This is a human-readable summary of what a real `bv` recommendation means. The actual robot output is JSON and includes fields such as `id`, `title`, `reasons`, `claim_command`, and `show_command`.

```text
Top recommendation: br-101
Why: unblocked, high downstream impact, and required by br-103 and br-105
What to do next: claim br-101 in Agent Mail, reserve the relevant files, and start there
```

### Sample Agent Mail Start Message

```text
thread_id="br-103"
subject="[br-103] Start: Failed-ingestion admin screen"

Claiming br-103. I am taking the admin failure-review surface and reserving the relevant admin UI files plus the retry handler path. I will send another update once the list view is working and the retry path is wired.
```

### Sample Agent Mail Completion Message

```text
thread_id="br-103"
subject="[br-103] Completed"

Completed the first failed-ingestion admin screen. The list view, detail view, and retry action are wired. Auth checks are in place. I also added coverage for malformed upload -> admin review -> retry.
```

The methodology becomes concrete when the artifacts line up and tell the same story.

The rest of this guide returns to those same artifacts from different angles. That is deliberate; a newcomer usually needs to see the same object first as an example, then as a rule, then as an operating habit.

## Why There Are Multiple Walkthroughs

The walkthrough sections are doing different jobs:

- `One Concrete Example` gives you the first intuition for the whole loop
- `Sample Artifact Packet` shows what the key artifacts look like side by side
- `Annotated First Run` gives you the movie
- `Literal First Session Transcript` gives you the operator sequence
- `A Tiny End-to-End Happy Path` shows the smallest runnable loop
- `A Minimal First Project Recipe` gives you the startup checklist

They overlap on purpose. A newcomer usually needs the same workflow in more than one representation before it feels natural.

## Annotated First Run

Here is the same Atlas Notes example again, this time as a short movie rather than a packet of separate artifacts:

1. **Plan the project.** You collect competing markdown plans, then synthesize them into one plan that clearly covers upload flow, parse failures, search, admin review, auth, and tests.
2. **Create the first beads.** You turn that plan into concrete work units such as `br-101` for the upload pipeline, `br-103` for failed-ingestion admin review, and `br-105` for end-to-end tests.
3. **Add the dependency edges.** You encode the obvious realities of the system, e.g. `br-103` depends on `br-101`, because the admin review screen makes no sense before the upload and parse pipeline exists.
4. **Ask `bv` where execution should begin.** It recommends `br-101` first because it is unblocked and because other important beads depend on it.
5. **Claim the bead in Agent Mail.** An agent announces that it is taking `br-101`, reserves the relevant files, and starts implementation.
6. **Implement and report progress.** The code changes happen against a real bead with a real thread, not as a vague conversational side quest.
7. **Close the bead and ask what is next.** Once `br-101` is complete, the graph changes. `bv` now has better information and may push `br-103` or `br-105` upward.

That sequence is the heartbeat of the core loop: plan, encode, route, claim, implement, close, repeat.

## Literal First Session Transcript

Here is a compact version of what a first real session can look like in operator terms:

```text
1. Ask three strong frontier models for a markdown plan for Atlas Notes.
2. Read their plans side by side.
3. Run the canonical synthesis prompt on one of the strongest models.
4. Save the resulting markdown plan as the current working plan.

5. Create the first beads:
   br create --title "Upload and parse pipeline" --type task --priority 1
   br create --title "Failed-ingestion admin screen" --type task --priority 1
   br create --title "End-to-end ingestion tests" --type task --priority 1

6. Add the first obvious dependencies:
   br dep add 103 101
   br dep add 105 101

7. Ask the graph what to do first:
   bv --robot-next

8. Join the coordination layer:
   ensure_project(project_key="/path/to/repo")
   register_agent(project_key="/path/to/repo", program="claude-code", model="opus")

9. Claim the first bead:
   file_reservation_paths(..., reason="br-101")
   send_message(..., thread_id="br-101", subject="[br-101] Start: Upload and parse pipeline")

10. Implement the bead, run the relevant tests, and do a fresh-eyes review.

11. Close the bead:
    br close 101 --reason "Completed"
    send_message(..., thread_id="br-101", subject="[br-101] Completed")

12. Ask the graph what changed:
    bv --robot-next
```

This is only the first clean pass through the loop, in the order a real operator would feel it.

### Try This Now

If you want to feel the method instead of only reading about it:

1. pick one real repo
2. write one serious markdown plan
3. create two real beads in `br`
4. add one real dependency
5. run `bv --robot-next`
6. claim one bead in Agent Mail

Those six steps are enough to make the core loop stop feeling theoretical.

## A Simple Mental Model

If the terms still feel abstract, think of the three tools this way:

| Tool | Intuitive picture |
|------|-------------------|
| [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) | the shared radio plus reservation board |
| [`br`](https://github.com/Dicklesworthstone/beads_rust) | the project map |
| [`bv`](https://github.com/Dicklesworthstone/beads_viewer) | the dispatcher that keeps pointing at the best next route |

The analogy is loose, but it is close enough to make the workflow easy to hold in your head.

## The Artifact Ladder

One reason agentic coding feels confusing at first is that the active artifact keeps changing. The easiest way to stay oriented is to know what the current artifact means.

| Stage | Main artifact | What it means | What you do next |
|------|---------------|---------------|------------------|
| Raw idea | A rough description of the project | You know the goal, but not the system | Turn it into a serious markdown plan |
| Markdown plan | The project in design form | Workflows, constraints, architecture, and tests are visible | Convert it into beads |
| Bead graph | The plan encoded as executable work | Dependencies and task boundaries are explicit | Ask `bv` what matters next |
| Ready bead | A bead with no blockers | It can be started now | Claim it and reserve the surface |
| Claimed bead | A bead an agent is actively working on | The swarm should see who owns it | Implement, test, update progress |
| Completed bead | Finished work with status updated | The graph has changed | Ask `bv` for the next best ready bead |

```text
idea
  -> markdown plan
  -> beads
  -> bv picks ready bead
  -> Agent Mail claim
  -> implementation
  -> close bead
  -> next bead
```

### Current Working Set

Once the loop is live, a human operator is usually bouncing among just a few artifacts:

- the current markdown plan, which still defines the whole-system intent
- one `br show` view for the bead currently being shaped or executed
- one `bv --robot-next` or `bv --robot-triage` result showing what the graph thinks matters now
- one Agent Mail thread showing ownership, progress, and handoff state

If those four artifacts stay coherent, the loop usually feels calm. If they start contradicting each other, that is often the first sign that you need to repair the structure rather than push more code.

## Plan Space, Bead Space, and Code Space

Here is the smallest useful version of a distinction that becomes very important in the full methodology:

- **plan space** is where you decide the workflows, constraints, architecture, and testing expectations
- **bead space** is where you transform that thinking into executable memory for agents
- **code space** is where agents implement the local task that a bead defines

The general rule is simple. Debates belong in plan space. Translation and dependency shaping belong in bead space. Implementation belongs in code space. If the swarm starts discovering missing structure while coding, the answer is often to step back up into bead space or plan space instead of forcing more code through a weak task graph.

### Escalation Ladder

When something feels wrong, use the smallest escalation that actually fits the problem:

- if the issue is local code confusion, stay in code space and resolve it there
- if the bead is weak or underspecified, step back into bead space and rewrite the bead
- if the graph is wrong, fix the dependencies or add the missing bead
- if the plan is missing work, step back into plan space and revise the markdown plan
- if the agent itself is degraded, loopy, or confused after recovery attempts, restart it

That ladder keeps you from overreacting and also keeps you from trying to solve a planning problem with more code.

## The First 30 Minutes

If you want the fastest possible feel for the system, this is the first half hour:

1. Pick one real project, not a toy.
2. Ask multiple frontier models for competing markdown plans.
3. Synthesize them into one strong plan.
4. Create the first meaningful beads in `br`.
5. Add the most obvious dependencies.
6. Run `bv --robot-triage` or `bv --robot-next`.
7. Launch 2-4 agents however you prefer.
8. Have each agent coordinate through Agent Mail and claim a real bead.

If you do just that much cleanly, you will already feel what the core loop is buying you.

Start smaller than your ego wants to:

- 1 agent: learn the artifact flow without coordination overhead
- 2 agents: feel the first real coordination benefits
- 4 agents: feel meaningful swarm behavior

You do not need to start with eight agents for the methodology to be real.

### What You Should Have After 30 Minutes

If the first half hour went well, you should usually have:

- one strong markdown plan
- two or three real beads in `br`
- at least one real dependency edge
- one Agent Mail thread or claim in motion
- one `bv` recommendation that you actually agree with

Use that checkpoint to tell whether you are still learning the method or whether the loop has actually started operating.

### Solo / Pair / Swarm Modes

| Mode | What it is good for |
|------|----------------------|
| `1 agent` | Learn the artifact flow and get comfortable with plans, beads, and `bv` without coordination overhead |
| `2 agents` | Feel the first real coordination benefits and start using Agent Mail claims and reservations seriously |
| `4 agents` | Experience meaningful swarm behavior where routing, handoff, and graph quality start to matter a lot |

The methodology works in all three modes. The difference is not whether the loop is "real"; the difference is how much coordination pressure you put on the system.

### A Tiny Kickoff Packet

When a new agent joins the loop, the kickoff does not need to be huge. A compact version is usually enough:

```text
Read AGENTS.md and README.md carefully.
Understand what this repo does and how it is structured.
Join Agent Mail and check for active agents or waiting messages.
Pick or claim one real bead. If you are not sure what to do next, use bv.
Do not get stuck in communication purgatory; announce what you are taking, then start working.
```

That packet usually suffices. It loads the local operating contract, joins the coordination layer, and pushes the agent toward actual execution rather than passive waiting.

## The Human's Job in the Core Loop

The human is still important here, even in the smaller version.

The human's main jobs are:

- keep the bead graph honest
- notice when a missing task or missing dependency has to be added
- restart or redirect agents when they drift
- keep the system moving instead of letting it stall in over-coordination

The human is not supposed to micromanage every code edit. The human is there to keep the structure clean enough that the agents can work effectively inside it.

### Minimum Viable `AGENTS.md`

Even in the smaller core-loop version, you usually still want a minimal `AGENTS.md`. It does not have to be a giant doctrine document. But it should at least say:

- what the repo is for
- what the stack is
- any non-negotiable safety or style rules
- how this project uses Agent Mail, `br`, and `bv`

Without even that much, agents are forced to infer too much from local code context.

Treat `AGENTS.md` as the swarm's durable operating manual. It tells a fresh or partially confused agent how to behave, what tools exist, what rules matter, and what "doing a good job" looks like in this repo.

Minimal skeleton:

```markdown
# AGENTS.md

## Project purpose
- Atlas Notes ingests internal Markdown notes, indexes them, and exposes search plus an admin review surface.

## Stack
- Next.js app
- backend ingestion pipeline
- search index
- Playwright e2e tests

## Core rules
- Use Agent Mail for claims, reservations, and progress updates.
- Use br bead IDs everywhere: thread_id, reservation reason, and status tracking.
- Use bv when deciding what to do next instead of guessing from local context.

## Coordination conventions
- Each real task should map to a bead such as br-123.
- Start work by posting a [br-123] Start message in Agent Mail.
- If you compact or lose context, reread this file before continuing.
```

Think of it as the minimum concrete structure that keeps a fresh agent from improvising the operating contract.

That also explains why rereading it after compaction matters so much. The short recovery prompt is:

```text
Reread AGENTS.md so it's still fresh in your mind.
```

If an agent still seems confused, loopy, or operationally weird after rereading it, stop trying to rescue the degraded state and start a fresh session instead.

### Human Control Loop

During active execution, a good operator usually checks the swarm every 10-15 minutes for a few simple things:

- are there still good ready beads, or has the graph gone stale?
- are any beads stuck in `in_progress` without meaningful movement?
- do any Agent Mail claims or reservations overlap suspiciously?
- did implementation reveal a missing dependency or a missing bead?
- if the current open and in-progress beads all land cleanly, will they actually close the remaining gap?

This is also where practical recovery happens. If an agent compacts and starts acting strange, reload the local operating context, especially `AGENTS.md`, or restart the session if the behavior does not improve.

#### Literal 15-Minute Operator Sweep

One literal operator sweep can be as simple as this:

1. Run `bv --robot-next` or `bv --robot-triage` and check whether the top recommendation still makes sense.
2. Glance through the relevant Agent Mail threads or inbox entries for fresh claims, blockers, or silence.
3. Look for stale reservations or beads that still read as owned but have not moved.
4. Restart or redirect one drifting agent if something looks loopy, confused, or stuck.
5. Ask whether the current open and in-progress beads still close the remaining goal gap.

That is usually enough to keep the loop healthy without turning the human into a full-time traffic cop.

## The First Step Is Still Multi-Model Markdown Planning

Keep one fact in view: the core loop is still planning-first.

You do not begin by spawning agents into a vague idea. You begin by creating an excellent markdown plan. In practice, that usually means asking multiple frontier models to produce competing plans, then using one of the strongest models, often GPT Pro in the web app, to synthesize them into a better hybrid.

This is especially important because website-only models still matter here. GPT Pro, Claude in the web app, Gemini, and similar systems are often strongest during the big-picture planning phase, before work gets translated into beads.

If you do not have one specific premium model, the method still works. Use the strongest distinct models you do have. The important part is not one subscription; it is getting genuinely competing plans and then synthesizing them honestly.

The planning micro-workflow is:

1. Ask 3 strong models for independent plans.
2. Compare them honestly instead of treating your first draft as sacred.
3. Run the synthesis prompt on one of the strongest models.
4. Integrate the revisions into one canonical markdown plan.

### What a Good Plan Looks Like

A strong plan lets a fresh reader answer five questions without guessing:

- what are the main workflows?
- what constraints matter?
- what architecture are we actually choosing?
- how will we know it works?
- what failure cases must not disappear into hand-waving?

The texture should look more like this:

```markdown
## Upload workflow
- Users drag Markdown files into the upload surface.
- The system parses frontmatter plus body text and stores a normalized note record.

## Constraints
- Unauthorized users must never see note content or note metadata.
- Failed ingestions must be preserved for operator review instead of discarded.

## Architecture choice
- Use a dedicated ingestion pipeline so parse failures can be persisted and retried.
- Keep search indexing separate from upload handling so indexing can be retried independently.

## Tests and failure handling
- Unit coverage for parsing and index mapping.
- E2E coverage for upload, failed-ingestion review, retry, search, and filtering.
```

It gives a fresh agent workflows, constraints, architecture, testing, and failure handling in one place.

One canonical synthesis prompt is:

```text
I asked 3 competing LLMs to do the exact same thing and they came up with pretty different plans which you can read below. I want you to REALLY carefully analyze their plans with an open mind and be intellectually honest about what they did that's better than your plan. Then I want you to come up with the best possible revisions to your plan (you should simply update your existing document for your original plan with the revisions) that artfully and skillfully blends the "best of all worlds" to create a true, ultimate, superior hybrid version of the plan that best achieves our stated goals and will work the best in real-world practice to solve the problems we are facing and our overarching goals while ensuring the extreme success of the enterprise as best as possible; you should provide me with a complete series of git-diff style changes to your original plan to turn it into the new, enhanced, much longer and detailed plan that integrates the best of all the plans with every good idea included (you don't need to mention which ideas came from which models in the final revised enhanced plan):
```

The prompt asks for competitive synthesis rather than a summary. Its job is to force the model to admit where the other plans are better, then merge the strongest ideas into one much more complete planning artifact.

### How to Know the Plan Is Ready

Before you turn the plan into beads, check:

- the main user workflows are explicit
- the important constraints are visible
- the key architectural choices are no longer hand-wavy
- the testing expectations are named
- obvious failure cases are acknowledged
- there are no giant "someone will figure this out later" holes
- a fresh agent could turn it into beads without repeatedly coming back to interview you

### Plan-to-Beads Coverage Check

Before launch, make one harder pass over the transition from plan space into bead space:

- does every important user workflow in the plan land somewhere in the bead graph?
- does every key constraint land somewhere in the bead graph?
- do the major test obligations land somewhere in the bead graph?
- does failure handling land somewhere in the bead graph?

The sharp rule is simple: every important workflow, constraint, and test obligation in the plan should land somewhere in the bead graph. If not, do not launch yet.

Once that synthesized markdown plan exists, the three-tool core loop takes over.

If that last bullet is not true yet, stay in plan space longer. It is cheaper there.

## Weak vs. Strong Artifacts

Quality thresholds get easier to feel when you compare weak and strong versions directly.

### Weak vs. Strong Plan Bullet

Weak:

```markdown
- Add auth
```

Strong:

```markdown
- Internal-only auth gates every note and note-metadata surface.
- Unauthorized users must never see content, filenames, tags, or timestamps.
- Admin review routes require explicit permission checks and should be covered by e2e tests for allowed and denied access.
```

The weak version names a topic. The strong version scopes the actual requirement, the constraint, and the testing obligation.

### Weak vs. Strong Bead

Weak:

```markdown
br-204: Improve search
```

Strong:

```markdown
br-204: Search result filtering and sorting

Context:
The search index exists, but users still cannot filter by tag or date or choose relevance vs recency sorting.

Task:
Implement filter controls plus sort selection and connect them to the existing query path.

Definition of done:
- tag filter works
- date filter works
- relevance and recency sort both work
- empty states remain intelligible

Tests:
- unit coverage for query-parameter mapping
- e2e coverage for filter and sort behavior
```

The weak bead is only a slogan. The strong bead is something another agent can actually execute.

## Why These Three Tools Matter

These three tools solve three different failure modes.

### Why Not Just Use GitHub Issues or Todo Lists?

Ordinary issue trackers and todo lists are fine for many projects. The problem is that they usually do not combine all three properties this workflow needs at the same time:

- explicit dependency structure
- graph-aware routing for what should happen next
- lightweight coordination that survives crashes, compaction, and agent turnover

GitHub Issues can hold tasks, but they do not naturally become a graph-routed execution substrate. Plain todo lists are even weaker. The core loop is opinionated because agent swarms need tighter structure than ordinary solo development.

### 1. Agent Mail Solves Coordination

Without [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail), multiple agents constantly collide:

- two agents edit the same files
- nobody knows who is doing what
- messages disappear into chat history
- work gets stranded when an agent crashes or loses context

Agent Mail gives you a shared coordination layer with identities, threads, inboxes, and file reservations. In practice, that means agents can announce what they are doing, reserve edit surfaces, and recover when another agent disappears.

### 2. `br` Solves Task Structure

Without [`br`](https://github.com/Dicklesworthstone/beads_rust), work tends to collapse into vague conversational intentions:

- "fix the auth stuff"
- "clean up the admin area"
- "someone should improve tests"

That kind of tasking is too fuzzy for a swarm. `br` turns work into explicit beads with status, priority, and dependencies. Once the work is represented that way, it becomes much easier for multiple agents to make progress without constant human steering.

### 3. `bv` Solves Routing

Even if you have good beads, agents still need to know what to do next. Without [`bv`](https://github.com/Dicklesworthstone/beads_viewer), they often choose work based on local convenience or whatever they most recently saw in context.

`bv` reads the bead graph and computes what is most worth doing next. That turns the swarm from "many agents doing work" into "many agents pushing the project forward efficiently."

## What Goes Wrong If You Skip One Tool

| If you skip... | What usually happens |
|----------------|----------------------|
| [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) | Agents overlap, duplicate work, and lose shared situational awareness |
| [`br`](https://github.com/Dicklesworthstone/beads_rust) | Work stays vague, hidden in chat, and hard to coordinate across agents |
| [`bv`](https://github.com/Dicklesworthstone/beads_viewer) | Agents pick tasks based on convenience instead of graph-aware leverage |

Each tool helps on its own, but the value shows up most clearly when they form a stable loop together.

## One Convention That Makes the Whole Thing Hang Together

Use the bead ID everywhere.

If the task is `br-123`, then:

- the Agent Mail thread should also be `br-123`
- the subject line should usually start with `[br-123]`
- the file reservation reason should mention `br-123`

This guide uses `br-123` as a generic stand-in. Real workspaces can use a different configured prefix or ID shape, such as `bd-ljd1`. The important part is consistency across the bead, the thread, and the reservation reason.

A tiny concrete example:

- bead: `br-123` = "Build upload and parse pipeline"
- Agent Mail thread: `thread_id="br-123"`
- start message subject: `[br-123] Start: Upload pipeline`
- reservation reason: `br-123`

It sounds small, but it is one of the most practical conventions in the whole workflow. The task graph, the coordination thread, and the work claim all line up under the same identifier. Once you do that consistently, the system becomes much easier to inspect and recover when something goes wrong.

### One Bead Through Its Full Lifecycle

| Stage | What happens |
|-------|--------------|
| `created` | `br-145` is created with title, context, dependencies, and test expectations |
| `ready` | its blockers are cleared, so `bv` can recommend it |
| `claimed` | an agent posts `[br-145] Start` in Agent Mail and reserves the relevant files |
| `in_progress` | code and tests are actively being written against the bead |
| `completed` | the implementation and tests are done, and the agent posts `[br-145] Completed` |
| `closed` | the bead status is closed in `br`, and the graph is ready for the next routing decision |

### Status Map

```text
open -> ready -> claimed -> in_progress -> completed -> closed
```

The line compresses the lifecycle into one mental model. `br` owns the task state. `bv` cares most about whether something is ready and worthwhile. Agent Mail makes the claimed / in-progress / completed parts visible to the swarm.

#### State Ownership Map

| State | Who owns or computes it |
|-------|--------------------------|
| `open` | `br` task status |
| `in_progress` | `br` task status |
| `closed` | `br` task status |
| `ready` | computed from the graph by `bv` |
| `claimed` | visible operationally in Agent Mail thread usage and reservations |
| `completed` | operational checkpoint just before closure, usually visible in Agent Mail and local workflow before `br close` |

This matters because the lifecycle is cross-tool. A newcomer can easily assume every state belongs to `br`. It does not. The workflow works because the tools each own different parts of the same operational story.

## Launch Readiness Checklist

The launch threshold has two stages.

### Ready to convert the plan into beads

- the markdown plan is strong enough
- the major workflows are covered
- the key constraints and architecture choices are visible
- the testing expectations are explicit
- a fresh agent could create beads from the plan without guessing

### Ready to launch agents into the bead graph

- the first real beads exist
- the important dependencies have been added
- at least one ready bead exists
- bead IDs are being used consistently
- Agent Mail / `br` / `bv` usage conventions are understood

### What Not Ready Looks Like

These are common signs that you are still too early:

- auth is mentioned somewhere in the plan, but no bead scopes what auth actually means
- tests are implied as a nice idea, but no bead names the required coverage
- admin review exists in prose, but nothing in the bead graph actually owns that surface
- `bv` keeps surfacing weak or obviously premature work because the dependency graph is still skeletal

When you see those patterns, stay in plan space or bead space longer. Launching agents does not fix missing structure.

## The Minimal Operating Loop

If you only remember one section from this document, remember this one.

### Step 1: Create an Excellent Markdown Plan

Before beads or swarms or file reservations, create a serious markdown plan.

Do not settle for one quick draft from one model. The higher-leverage move is:

- get multiple frontier models to propose competing plans
- include website-only models like GPT Pro when they are strong for this kind of reasoning
- synthesize the best parts into one much better plan

At minimum, you want:

- the user-facing workflows
- the important constraints
- the major architectural decisions
- the testing expectations

This does not have to be a 6,000-line monster immediately. But it does need to be strong enough that another agent could understand what success looks like and what the major tradeoffs are.

### Step 2: Turn the Plan into Beads

Now use [`br`](https://github.com/Dicklesworthstone/beads_rust) to create actual beads.

Use beads as real work units, not vague slogans.

Good beads usually include:

- what needs to be done
- relevant background or rationale
- what it depends on
- what counts as done
- what tests need to exist

The more explicit the bead graph is, the less improvisation the swarm has to do later.

#### Beads as Executable Memory

The markdown plan is the best artifact for whole-system thought. Beads are the plan after it has been transformed into a format optimized for distributed execution.

That matters because swarms do not need a beautiful essay during implementation. They need a task graph that carries enough local context for work to survive compaction, handoff, and agent replacement. Weak beads force improvisation. Rich beads make execution much more mechanical.

#### What a Good Bead Looks Like

Here is the texture you are aiming for:

```markdown
br-145: Search result filtering and sorting

Context:
The markdown plan says users must be able to filter by tag and date and sort results by relevance or recency. The search index exists, but the filtering and sort controls are still missing.

Task:
Implement the first filter/sort layer in the search UI and connect it to the existing query path.

Why:
Without this, the search flow technically works but does not satisfy the actual product requirement from the plan.

Depends on:
- br-102 search index and query path

Definition of done:
- user can filter by tag
- user can filter by date range
- user can switch between relevance and recency sort
- empty states remain intelligible

Tests:
- unit coverage for query-parameter mapping
- e2e coverage for tag filter, date filter, and sort switching

Likely touch points:
- search results page
- search query parser / request layer
- filter controls component

Coordination note:
- announce the claim in thread br-145 before touching shared search UI files
```

The prose does not need polish. A fresh agent should be able to understand the task, the reason for it, the dependency context, and the test obligations without reopening the whole markdown plan.

#### Where the Bead Detail Actually Lives

Newcomers often get confused here because the command examples are short while the bead examples are rich. The command examples are only showing the minimal CLI surface. The real task detail needs to live somewhere durable and immediately retrievable by the agent:

- directly in the bead body, description, or notes, if that is how your local setup stores long-form bead context
- or in an adjacent markdown artifact that the bead clearly points to and that agents treat as the bead's expanded context

The important rule is not one exact storage format. The important rule is that the bead, or something directly attached to it, carries enough context that the agent does not have to reopen the original master plan or ask the human to restate the task.

In practice, common patterns look like this:

- short title in `br`, with the long-form execution detail stored in the bead body or note field
- short title plus compact bead body in `br`, with a nearby markdown artifact linked for deeper rationale or UI details
- one canonical project markdown plan, then execution-grade bead notes that carry only the local context needed for the task at hand

What does not work well is a tiny title with no durable expansion anywhere. If the real task detail only lives in somebody's memory or in old chat scrollback, the bead is too weak.

#### How I Actually Author a Rich Bead

Using the real `br` CLI surface, a common authoring pattern looks like this:

```bash
# create the bead with a clear title and basic metadata
br create --title "Search result filtering and sorting" --type task --priority 1

# then enrich it with the execution detail
br update 145 \
  --description "The markdown plan requires tag/date filtering and relevance/recency sorting in the search UI." \
  --design "Use the existing query path. Keep filter state explicit in the request layer. Avoid introducing a second search codepath." \
  --acceptance-criteria "Tag filter works. Date filter works. Relevance and recency sorting both work. Empty states stay intelligible." \
  --notes "Add unit coverage for query mapping and e2e coverage for filter/sort behavior. If deeper UI rationale exists, link the nearby markdown artifact here."
```

One realistic pattern is to create the bead shell first, then use `br update` to attach the long-form description, design notes, acceptance criteria, and additional notes that make the bead execution-ready. If you keep deeper UI or architecture rationale in a nearby markdown artifact, the bead should point to it explicitly rather than assuming the agent will rediscover it.

#### What This Looks Like in `br`

Here is a real `br show` text view captured from a live workspace. The project-specific title and prefix will differ in your own repo, but the output shape is real:

#### Canonical Commands vs. Live Captures

This guide teaches [`br`](https://github.com/Dicklesworthstone/beads_rust) as the canonical command for new use.

Some of the live captures below come from older or differently configured workspaces that emit `bd-*` IDs or `bd show` / `bd update` command strings. Treat those as real examples of output shape, not as the command you should prefer when starting fresh. For new work, use `br`.

```text
○ bd-ljd1 · task(asupersync-arch): inventory runtime-shell seams, doctor orchestration seams, and explicit no-go zones   [● P1 · OPEN]
Owner: ubuntu · Type: task
Created: 2026-03-09 · Updated: 2026-03-09
Labels: architecture, asupersync, doctor_frankentui, frankentui, inventory

Inventory the exact integration seams in ftui-runtime and doctor_frankentui before any migration work begins. Capture where the current code uses threads, channels, condvars, polling loops, sleeps, stop signals, timeouts, and process management. Also mark the areas that must remain synchronous for correctness or performance.

Design:
The output should be a bead-contained map of current behavior and hotspots, not a vague impression. It should tie each seam to concrete user or operator pain such as shutdown lag, leaked work, nondeterministic tests, or difficult failure triage.

Acceptance Criteria:
Primary seams and no-go zones are named explicitly. User-visible pain points are recorded. Later beads can point back to this task instead of rediscovering the architecture from scratch.

Notes:
This is effectively the ground-truth survey for the whole migration.
```

Expect a compact header plus the long-form body sections that make the bead executable. Some workspaces will also show dependency sections such as `Depends on` or `Dependents`, depending on the issue.

Minimal `br` commands:

```bash
br create --title "Implement auth and permissions" --type task --priority 1
br create --title "Build upload and parse pipeline" --type task --priority 1
br dep add 102 101
br ready --json
```

### Step 3: Let `bv` Tell You What Matters Next

Once the bead graph exists, stop relying on intuition for task ordering.

Use [`bv`](https://github.com/Dicklesworthstone/beads_viewer) to see:

- what is ready right now
- what clears the most downstream blockers
- what work has outsized impact on overall velocity

This is a major shift in the methodology. The graph should do the routing work for you.

#### How to Read `bv` Output

Do not stare at the JSON forever. Look for:

- the top recommendation
- why it is top
- what it unblocks

A typical mental interpretation is:

```text
Top recommendation: br-101
Reason: unblocked, high downstream impact, and required by br-103 and br-105
Action: claim br-101 in Agent Mail, reserve the relevant files, and start there
```

In a real `--robot-next` response, the shape looks more like this:

```text
{
  "id": "bd-ljd1",
  "title": "task(asupersync-arch): inventory runtime-shell seams, doctor orchestration seams, and explicit no-go zones",
  "score": 0.411364061085006,
  "reasons": [
    "🎯 Completing this unblocks 3 downstream issues (bd-1qmd, bd-1vwf, bd-2q5d)",
    "📊 High centrality in dependency graph (PageRank: 100%)",
    "⚡ Low effort, high impact - good starting point",
    "✅ Currently unclaimed - available for work",
    "🚨 High priority (P1) - prioritize this work"
  ],
  "unblocks": 3,
  "claim_command": "bd update bd-ljd1 --status=in_progress",
  "show_command": "bd show bd-ljd1"
}
```

The exact ID prefix and command strings can vary by workspace configuration. Read the output for its intent: what to do next, why it matters, and what command or bead to inspect.

#### When `bv` Is Telling You to Fix the Graph, Not Write Code

Sometimes the right response to `bv` is not "follow the recommendation." Sometimes the right response is "the graph itself still needs work." Common signals:

- there are no good ready beads even though the project obviously has meaningful work left
- the top recommendation is technically ready but clearly low-value or premature
- the same low-leverage kind of work keeps rising because dependencies are missing or malformed
- too many stale blockers are piling up and the recommendations feel detached from the real project bottlenecks

When that happens, go back up one level. Add the missing bead, fix the dependencies, or improve the bead bodies. `bv` is a routing tool, but it is also a graph-quality diagnostic.

Minimal `bv` commands:

```bash
bv --robot-triage
bv --robot-next
```

### Step 4: Coordinate Through Agent Mail

When an agent starts a bead, it should use [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) to do two things:

- communicate what it is working on
- reserve the relevant files or surfaces

That keeps the swarm legible. Other agents can see what is happening. If someone crashes, the thread is still there. If there is overlap, the reservation system makes it visible.

#### Who Does What?

| Actor | Main responsibility |
|-------|----------------------|
| human operator | shapes the plan, repairs the graph, notices missing work, and intervenes when structure is wrong |
| coding agent | implements the bead, runs tests, posts start/progress/completion updates, and follows the local operating contract |
| Agent Mail MCP layer | carries the coordination state: identity, thread history, reservations, and acknowledgements |

In some setups the human explicitly invokes the Agent Mail actions; in others the coding agent does. What matters is where the coordination state lives: in the mail layer, not only in somebody's head or chat scrollback.

#### Typical Agent Mail Thread Lifecycle

In practice, a bead thread often has a rhythm like this:

```text
[br-123] Start: I am taking this bead and reserving the relevant files.
[br-123] Progress: The main path is wired; I am now handling edge cases and tests.
[br-123] Completed: Implementation and tests are done; the bead can be closed.
```

Three short updates are usually enough to keep the work visible and handoff-friendly. Another agent should be able to drop into the same thread and immediately understand ownership, current status, and completion state.

These are Agent Mail / MCP calls, not shell commands. They represent the coordination actions you want the agent to take through the mail layer.

Minimal Agent Mail flow:

```text
ensure_project(project_key=<repo>)
register_agent(project_key, program, model)
file_reservation_paths(..., reason="br-123")
send_message(..., thread_id="br-123", subject="[br-123] Start: ...")
```

### Step 5: Finish the Bead, Update the Graph, Repeat

As work completes:

- update bead status in `br`
- send progress or completion notes through Agent Mail
- ask `bv` what the next best ready bead is

#### Fresh Eyes After Each Bead

One of the cheapest quality multipliers in the whole method is to make the agent review its own work immediately after finishing a bead:

```text
great, now I want you to carefully read over all of the new code you just wrote and other existing code you just modified with "fresh eyes" looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover.
```

Treat this as part of the normal loop. The point is to force a mode switch from writing to adversarial reading while the code is still fresh. For simple beads, one pass may be enough. For more complex work, run it again until the agent reports that it reviewed everything and found nothing worth fixing.

Minimal close-the-loop commands:

```bash
br update 123 --status in_progress
br close 123 --reason "Completed"
bv --robot-next
```

That completes one pass through the loop.

The rhythm is:

`multi-model plan -> encode in beads -> triage with bv -> coordinate with Agent Mail -> implement -> update -> repeat`

## A Tiny End-to-End Happy Path

Here is a deliberately small version of the whole thing:

```bash
# create beads
br create --title "Upload pipeline" --type task --priority 1
br create --title "Search index" --type task --priority 1
br dep add 102 101

# see what matters first
bv --robot-next
```

Then in Agent Mail terms:

```text
ensure_project(project_key="/path/to/repo")
register_agent(project_key="/path/to/repo", program="claude-code", model="opus")
file_reservation_paths(..., reason="br-101")
send_message(..., thread_id="br-101", subject="[br-101] Start: Upload pipeline")
```

After implementation:

```bash
br update 101 --status in_progress
br close 101 --reason "Completed"
bv --robot-next
```

And the completion message would stay in the same Agent Mail thread:

```text
send_message(..., thread_id="br-101", subject="[br-101] Completed")
```

That miniature loop is the core pattern.

### First Success Looks Like This

The first genuinely encouraging signal is not "we wrote some code." It is something more structured:

- one bead was claimed cleanly
- one bead was finished and closed
- `bv` changed its recommendation afterward because the graph actually moved
- another agent could understand what happened from the bead plus the thread alone

Once that happens, the method usually stops feeling theoretical.

## Common Failure Modes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Agents keep overlapping | Weak or missing Agent Mail claims and reservations | Force thread use, reserve surfaces, restate ownership |
| Agents choose random work | The team is not using `bv` consistently | Run `bv --robot-triage` and route from the graph |
| A task keeps stalling | The bead is underspecified or missing a dependency | Rewrite the bead or add the missing dependency |
| The swarm feels busy but confused | The markdown plan was too weak | Go back up a level and improve the plan before continuing |

### Agent Disappeared Mid-Bead

When an agent vanishes or stops responding in the middle of a bead, the recovery path should be boring:

1. Check the Agent Mail thread for the last meaningful progress update.
2. Check whether the file reservation is still active and whether it looks abandoned.
3. Reread `AGENTS.md` so the local operating contract is fresh again.
4. If the original session is still salvageable, resume it. If it is loopy or clearly degraded, restart it.
5. Reclaim the bead explicitly in Agent Mail so ownership is visible.
6. Continue from the bead body plus the thread history instead of guessing.

If that recovery feels hard, the bead or the thread was probably too thin.

### High-Level Reality Check

When the swarm looks active but you suspect it is not actually closing the real gap, stop and ask a higher-level question:

```text
Where are we on this project? Do we actually have the thing we are trying to build? If not, what is blocking us? If we intelligently implement all open and in-progress beads, would we close that gap completely? Why or why not?
```

Use this as a high-value human intervention. If the answer is "no," the fix is usually not more implementation effort. Revise the bead graph, add missing work, or step back into planning.

## What This Feels Like Once It Clicks

At that point, the workflow stops feeling like extra ceremony and starts feeling like a calmer control surface:

- less duplicated work, because ownership and reservations are explicit
- less "what should I do next?" drift, because `bv` keeps answering that question
- easier restart after context loss, because the work lives in beads and threads instead of only in chat history
- easier handoff, because another agent can read the bead, read the thread, and continue

That operator feeling is a good sign. It usually means the artifacts are carrying the work instead of your short-term memory.

## Why This Captures Most of the Value

People often assume the magic of the Flywheel comes from the total number of tools. It does not.

Most of the value comes from three things:

1. work is explicit instead of implicit
2. coordination is externalized instead of living in human memory
3. task choice is graph-aware instead of random

Those three properties are already present in the core loop.

That is why the smaller system gets you surprisingly far.

## What You Can Ignore For Now

If you are just getting started, you do not need to master all of this immediately:

- large-scale session memory systems like CASS and CM
- big prompt libraries
- advanced launch tooling like `acfs agents`
- the full exhaustive planning doctrine
- every supporting tool in ACFS

Those things help. Some help a lot. But they are multipliers on top of the core loop, not prerequisites for understanding it.

You can even run the core loop without any special session manager. Separate tabs in WezTerm, tmux, Ghostty, or any other terminal setup are fine. The core loop cares about coordination and routing, not about one mandatory operator interface.

## What You Probably Should Not Ignore

Even in the smaller version, a few principles still matter a lot:

- do not start a swarm with only vague goals
- do not treat beads as tiny throwaway todo lines
- do not let agents choose work arbitrarily when `bv` can answer that better
- do not rely on chat scrollback as your coordination system

If you violate those, the workflow quickly degrades back into ordinary multi-agent chaos.

## A Minimal First Project Recipe

If you want the shortest real starting path, do this:

1. Pick one real project.
2. Ask multiple frontier models for competing markdown plans.
3. Use the canonical synthesis prompt above to turn them into one strong working plan.
4. Create beads in [`br`](https://github.com/Dicklesworthstone/beads_rust) with real dependencies.
5. Use [`bv`](https://github.com/Dicklesworthstone/beads_viewer) to inspect what is ready and what unblocks the most.
6. Launch 2-4 agents however you prefer.
7. Have them coordinate only through [Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) plus the bead graph.
8. Keep repeating the loop until the graph is empty or reveals missing work.

That short recipe is enough to feel the method in practice.

## When Not to Use the Core Loop

The core loop is powerful, but it is not the right hammer for every nail.

You probably do not need it for:

- a tiny one-file change with no real dependency structure
- a purely local experiment where you are just trying something out
- a quick one-agent cleanup that does not need externalized coordination

The loop earns its keep when work has enough structure, enough ambiguity, or enough parallelism that explicit planning, explicit tasks, and explicit coordination start paying for themselves.

For a tiny, bounded change that does not justify a full bead, use a durable ad hoc checklist or TODO flow instead. Keep the work externalized. If the task starts expanding, touching multiple surfaces, or spawning dependencies, convert it into a real bead before the ambiguity spreads.

## When to Graduate to the Full Flywheel

Move up to the full guide when one or more of these becomes true:

- your projects are large enough that you want much richer planning
- you want stronger `AGENTS.md` operating manuals
- you want repeatable prompt libraries and skills
- you want better recovery from compaction and session loss
- you want memory systems that improve the workflow over time

At that point, the bigger document stops feeling like overhead and starts feeling like leverage.

## Appendix: Cheat Card

If you want the loop on one screen, keep this:

1. plan with multiple models
2. synthesize into one markdown plan
3. create beads in `br`
4. add dependencies
5. run `bv`
6. claim the bead in Agent Mail
7. implement
8. do a fresh-eyes review
9. close the bead
10. repeat

That sequence is not the whole philosophy. It is the smallest cheat card that still preserves the operating rhythm.

## Where to Go Next

- For the exhaustive version of the methodology, see [THE_FLYWHEEL_APPROACH_TO_PLANNING_AND_BEADS_CREATION.md](./THE_FLYWHEEL_APPROACH_TO_PLANNING_AND_BEADS_CREATION.md).
- If you already believe in the core loop, the next things worth adding are a stronger `AGENTS.md`, better planning habits, and a small set of battle-tested prompts.
