"use client";

import {
  Bug,
  Check,
  ChevronRight,
  Clock,
  Code2,
  Command,
  Copy,
  CornerDownLeft,
  FileText,
  FolderOpen,
  Hash,
  Keyboard,
  Layers,
  Lightbulb,
  Palette,
  Play,
  Search,
  Send,
  Settings,
  Sparkles,
  Star,
  TestTube,
  X,
  Zap,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion, useInView } from "@/components/motion";
import { copyTextToClipboard } from "@/lib/utils";
import {
  BulletList,
  CodeBlock,
  Divider,
  GoalBanner,
  Highlight,
  InlineCode,
  Paragraph,
  Section,
} from "./lesson-components";

export function NtmPaletteLesson() {
  return (
    <div className="space-y-8">
      <GoalBanner>Discover the pre-built prompts that supercharge your agents.</GoalBanner>

      {/* What Is The Command Palette */}
      <Section
        title="What Is The Command Palette?"
        icon={<Palette className="h-5 w-5" />}
        delay={0.1}
      >
        <Paragraph>
          ACFS ships with a <Highlight>command palette</Highlight> - a collection of
          battle-tested prompts for common development tasks.
        </Paragraph>
        <Paragraph>
          These aren&apos;t just prompts. They&apos;re carefully crafted instructions that get the
          best results from coding agents.
        </Paragraph>

        <div className="mt-6">
          <CodeBlock code={`less ${PALETTE_PATH}`} />
        </div>
        <Paragraph>
          This opens the file with all available prompts. Browse the same prompts here:
        </Paragraph>
        <div className="mt-8">
          <InteractivePaletteBrowser />
        </div>
      </Section>

      <Divider />

      {/* Palette Categories */}
      <Section title="Palette Categories" icon={<Layers className="h-5 w-5" />} delay={0.15}>
        <Paragraph>The prompts are organized into categories:</Paragraph>

        <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <CategoryCard
            icon={<Layers className="h-5 w-5" />}
            title="Architecture & Design"
            items={["System design analysis", "Architecture review", "API design patterns"]}
            gradient="from-violet-500/20 to-purple-500/20"
            delay={0.1}
          />
          <CategoryCard
            icon={<Code2 className="h-5 w-5" />}
            title="Code Quality"
            items={["Code review prompts", "Refactoring suggestions", "Bug hunting strategies"]}
            gradient="from-sky-500/20 to-blue-500/20"
            delay={0.2}
          />
          <CategoryCard
            icon={<TestTube className="h-5 w-5" />}
            title="Testing"
            items={["Test generation", "Coverage analysis", "Edge case discovery"]}
            gradient="from-emerald-500/20 to-teal-500/20"
            delay={0.3}
          />
          <CategoryCard
            icon={<FileText className="h-5 w-5" />}
            title="Documentation"
            items={["README generation", "API documentation", "Inline comment review"]}
            gradient="from-amber-500/20 to-orange-500/20"
            delay={0.4}
          />
          <CategoryCard
            icon={<Bug className="h-5 w-5" />}
            title="Debugging"
            items={["Error analysis", "Performance profiling", "Memory leak detection"]}
            gradient="from-red-500/20 to-rose-500/20"
            delay={0.5}
          />
        </div>
      </Section>

      <Divider />

      {/* Using Palette Prompts */}
      <Section title="Using Palette Prompts" icon={<Send className="h-5 w-5" />} delay={0.2}>
        <div className="space-y-8">
          <UsageOption
            number={1}
            title="Copy and Send"
            steps={[
              <>
                Open the palette: <InlineCode>less {PALETTE_PATH}</InlineCode>
              </>,
              "Select a prompt",
              "Copy it",
              <>
                Use <InlineCode>herdr agent prompt</InlineCode> or paste directly
              </>,
            ]}
          />

          <UsageOption number={2} title="Send From The Shell (Power Move)" steps={[]}>
            <div className="mt-4">
              <CodeBlock
                code={`# One-off prompt to one agent
herdr agent prompt myproject-cc1 "Review the changes in src/ for edge cases"

# The same prompt to every agent in the workspace, or to one kind
acfs agents send --all "Review the changes in src/ for edge cases"
acfs agents send --kind claude "Review the changes in src/ for edge cases"`}
              />
            </div>
            <p className="mt-3 text-white/60">
              herdr has no palette menu. <InlineCode>herdr agent prompt</InlineCode> sends to one
              agent by name or pane ID; <InlineCode>acfs agents send</InlineCode> picks recipients
              with <InlineCode>--all</InlineCode>, <InlineCode>--kind claude</InlineCode>,{" "}
              <InlineCode>--kind codex</InlineCode>, <InlineCode>--kind agy</InlineCode> or{" "}
              <InlineCode>--name N</InlineCode>, and checks that each agent took the prompt.
            </p>
          </UsageOption>
        </div>
      </Section>

      <Divider />

      {/* Example Prompts */}
      <Section title="Example Prompts" icon={<Sparkles className="h-5 w-5" />} delay={0.25}>
        <Paragraph>Here are a few examples from the palette:</Paragraph>

        <div className="mt-8 space-y-6">
          <ExamplePrompt
            title="Code Review"
            prompt={`Review this code with an emphasis on:
1. Security vulnerabilities
2. Performance issues
3. Code readability
4. Edge cases not handled

For each issue, provide:
- The specific problem
- Why it matters
- A suggested fix`}
            gradient="from-sky-500/20 to-blue-500/20"
          />

          <ExamplePrompt
            title="Architecture Analysis"
            prompt={`Analyze the architecture of this codebase:
1. Identify the main components
2. Map the data flow
3. Note any anti-patterns
4. Suggest improvements

Create a simple diagram if helpful.`}
            gradient="from-violet-500/20 to-purple-500/20"
          />
        </div>
      </Section>

      <Divider />

      {/* Customizing The Palette */}
      <Section
        title="Customizing The Palette"
        icon={<FolderOpen className="h-5 w-5" />}
        delay={0.3}
      >
        <Paragraph>You can add your own prompts. Keep them in your own copy of the palette:</Paragraph>

        <div className="mt-6">
          <CodeBlock
            code={`# Primary location
cp ${PALETTE_PATH} ~/command_palette.md

# Or in your project directory
./command_palette.md`}
          />
        </div>

        <Paragraph>Add your prompts to that markdown file, and send them the same way.</Paragraph>
      </Section>

      <Divider />

      {/* Pro Tips */}
      <Section title="Pro Tips" icon={<Lightbulb className="h-5 w-5" />} delay={0.35}>
        <div className="mt-4">
          <BulletList
            items={[
              <span key="1">
                <strong>Start broad, then narrow</strong> - Use high-level prompts first
              </span>,
              <span key="2">
                <strong>Combine agents</strong> - Send different prompts to different agents
              </span>,
              <span key="3">
                <strong>Build on responses</strong> - Use agent output in follow-up prompts
              </span>,
              <span key="4">
                <strong>Save good prompts</strong> - Add working prompts to your custom palette
              </span>,
            ]}
          />
        </div>
      </Section>

      <Divider />

      {/* Try It Now */}
      <Section title="Try It Now" icon={<Play className="h-5 w-5" />} delay={0.4}>
        <CodeBlock
          code={`# Open the palette
$ less ${PALETTE_PATH}

# Browse the categories
# Select something interesting
# Try sending it to your test agent
$ herdr agent prompt test-cc "<the prompt>"`}
          showLineNumbers
        />
      </Section>
    </div>
  );
}

// =============================================================================
// CATEGORY CARD - Display a palette category
// =============================================================================
function CategoryCard({
  icon,
  title,
  items,
  gradient,
  delay,
}: {
  icon: React.ReactNode;
  title: string;
  items: string[];
  gradient: string;
  delay: number;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay }}
      whileHover={{ y: -4, scale: 1.02 }}
      className={`relative rounded-2xl border border-white/[0.08] bg-gradient-to-br ${gradient} p-5 backdrop-blur-xl transition duration-500 hover:border-white/[0.15]`}
    >
      <div className="flex items-center gap-3 mb-4">
        <div className="text-white">{icon}</div>
        <h3 className="font-bold text-white">{title}</h3>
      </div>
      <ul className="space-y-2">
        {items.map((item, i) => (
          <li key={i} className="text-sm text-white/60 flex items-center gap-2">
            <div className="h-1 w-1 rounded-full bg-white/40" />
            {item}
          </li>
        ))}
      </ul>
    </motion.div>
  );
}

// =============================================================================
// USAGE OPTION - How to use the palette
// =============================================================================
function UsageOption({
  number,
  title,
  steps,
  children,
}: {
  number: number;
  title: string;
  steps: React.ReactNode[];
  children?: React.ReactNode;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, x: -20 }}
      animate={{ opacity: 1, x: 0 }}
      whileHover={{ x: 4, scale: 1.01 }}
      className="group relative rounded-2xl border border-white/[0.08] bg-white/[0.02] p-6 backdrop-blur-xl transition duration-300 hover:border-white/[0.15] hover:bg-white/[0.04] hover:shadow-lg hover:shadow-primary/10"
    >
      <div className="flex items-center gap-4 mb-4">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-gradient-to-br from-primary to-violet-500 text-white font-bold shadow-lg shadow-primary/20 group-hover:shadow-primary/40 group-hover:scale-110 transition duration-300">
          {number}
        </div>
        <h3 className="text-lg font-bold text-white group-hover:text-primary transition-colors">
          {title}
        </h3>
      </div>

      {steps.length > 0 && (
        <ol className="space-y-2 ml-14">
          {steps.map((step, i) => (
            <li
              key={i}
              className="text-white/70 flex items-center gap-2 group-hover:text-white/80 transition-colors"
            >
              <span className="text-primary font-medium">{i + 1}.</span>
              {step}
            </li>
          ))}
        </ol>
      )}

      {children}
    </motion.div>
  );
}

// =============================================================================
// EXAMPLE PROMPT - Display an example prompt
// =============================================================================
function ExamplePrompt({
  title,
  prompt,
  gradient,
}: {
  title: string;
  prompt: string;
  gradient: string;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      whileHover={{ y: -4, scale: 1.02 }}
      className={`group relative rounded-2xl border border-white/[0.08] bg-gradient-to-br ${gradient} overflow-hidden transition duration-300 hover:border-white/[0.15] hover:shadow-lg hover:shadow-primary/10`}
    >
      <div className="p-4 border-b border-white/[0.08] bg-black/20 group-hover:bg-black/30 transition-colors">
        <h3 className="font-bold text-white group-hover:text-primary transition-colors">{title}</h3>
      </div>
      <div className="p-4">
        <pre className="text-sm text-white/80 whitespace-pre-wrap font-mono group-hover:text-white/90 transition-colors">
          {prompt}
        </pre>
      </div>
    </motion.div>
  );
}

// =============================================================================
// INTERACTIVE PALETTE BROWSER - VS Code / Spotlight-style command palette
// =============================================================================

// The browser shows the prompts of the palette ACFS installs, in its order:
// id is the command_key, title the display label, category its "##" heading
// and fullText the prompt. ntm-palette-lesson.test.ts keeps them identical.
export const PALETTE_PATH = "~/.acfs/onboard/docs/ntm/command_palette.md";

export interface PaletteCommand {
  id: string;
  title: string;
  description: string;
  category: string;
  params?: string;
  fullText: string;
  starred?: boolean;
}

interface PaletteGroup {
  name: string;
  icon: React.ReactNode;
  color: string;
  gradient: string;
  badgeBg: string;
  badgeText: string;
}

export const PALETTE_GROUPS: PaletteGroup[] = [
  {
    name: "Analysis & Review",
    icon: <Search className="h-3.5 w-3.5" />,
    color: "sky",
    gradient: "from-sky-500/20 to-blue-500/20",
    badgeBg: "bg-sky-500/20",
    badgeText: "text-sky-400",
  },
  {
    name: "Coding & Development",
    icon: <Code2 className="h-3.5 w-3.5" />,
    color: "emerald",
    gradient: "from-emerald-500/20 to-teal-500/20",
    badgeBg: "bg-emerald-500/20",
    badgeText: "text-emerald-400",
  },
  {
    name: "Ensemble",
    icon: <Layers className="h-3.5 w-3.5" />,
    color: "violet",
    gradient: "from-violet-500/20 to-purple-500/20",
    badgeBg: "bg-violet-500/20",
    badgeText: "text-violet-400",
  },
  {
    name: "Documentation",
    icon: <FileText className="h-3.5 w-3.5" />,
    color: "amber",
    gradient: "from-amber-500/20 to-orange-500/20",
    badgeBg: "bg-amber-500/20",
    badgeText: "text-amber-400",
  },
  {
    name: "Planning & Workflow",
    icon: <Lightbulb className="h-3.5 w-3.5" />,
    color: "cyan",
    gradient: "from-cyan-500/20 to-sky-500/20",
    badgeBg: "bg-cyan-500/20",
    badgeText: "text-cyan-400",
  },
  {
    name: "Git & Operations",
    icon: <Settings className="h-3.5 w-3.5" />,
    color: "red",
    gradient: "from-red-500/20 to-rose-500/20",
    badgeBg: "bg-red-500/20",
    badgeText: "text-red-400",
  },
  {
    name: "Agent Coordination",
    icon: <Send className="h-3.5 w-3.5" />,
    color: "fuchsia",
    gradient: "from-fuchsia-500/20 to-pink-500/20",
    badgeBg: "bg-fuchsia-500/20",
    badgeText: "text-fuchsia-400",
  },
  {
    name: "Investigation",
    icon: <Bug className="h-3.5 w-3.5" />,
    color: "orange",
    gradient: "from-orange-500/20 to-amber-500/20",
    badgeBg: "bg-orange-500/20",
    badgeText: "text-orange-400",
  },
  {
    name: "Quick Commands",
    icon: <Zap className="h-3.5 w-3.5" />,
    color: "teal",
    gradient: "from-teal-500/20 to-emerald-500/20",
    badgeBg: "bg-teal-500/20",
    badgeText: "text-teal-400",
  },
];

export const PALETTE_COMMANDS: PaletteCommand[] = [
  // Analysis & Review
  {
    id: "fresh_review",
    title: "Fresh Review",
    description: "Reread the code you just wrote with fresh eyes and fix what you find",
    category: "Analysis & Review",
    fullText: `Great, now I want you to carefully read over all of the new code you just wrote and other existing code you just modified with "fresh eyes" looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover.`,
    starred: true,
  },
  {
    id: "check_other_agents_work",
    title: "Check Other Agents Work",
    description: "Review your fellow agents' code and fix root causes",
    category: "Analysis & Review",
    fullText: `Ok can you now turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues, etc. and carefully diagnose their underlying root causes using first-principle analysis and then fix or revise them if necessary? Don't restrict yourself to the latest commits, cast a wider net and go super deep! Use /effort max.`,
    starred: true,
  },
  {
    id: "randomly_inspect_code",
    title: "Randomly Inspect Code",
    description: "Trace random code paths deeply and fix the mistakes found",
    category: "Analysis & Review",
    fullText: `I want you to sort of randomly explore the code files in this project, choosing code files to deeply investigate and understand and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, I want you to do a super careful, methodical, and critical check with "fresh eyes" to find any obvious bugs, problems, errors, issues, silly mistakes, etc. and then systematically and meticulously and intelligently correct them. Be sure to comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in the AGENTS.md file.`,
  },
  {
    id: "analyze_beads_and_allocate",
    title: "Analyze Beads and Allocate",
    description: "Use bv to suggest each agent's best next work, over Agent Mail",
    category: "Analysis & Review",
    fullText: `Re-read AGENTS.md first. Then, can you try using bv to get some insights on what each agent should most usefully work on? Then share those insights with the other agents via agent mail and strongly suggest in your messages the optimal work for each one and explain how/why you came up with that using bv. Use /effort max.`,
  },
  {
    id: "check_orm_and_schemas",
    title: "Check ORM and Schemas",
    description: "Critically review the data models and schemas",
    category: "Analysis & Review",
    fullText: `Now reread AGENTS.md, read your README.md, and then I want you to use /effort max to super carefully and critically read the entire data ORM schema/models and look for any issues or problems, conceptual mistakes, logical errors, or anything that doesn't fit your understanding of the business strategy and accepted best practices for the design and architecture of databases for these sorts of ecommerce/saas projects/companies.`,
  },
  {
    id: "scrutinize_and_improve_workflow_and_ui",
    title: "Scrutinize and Improve Workflow and UI",
    description: "Find what is sub-optimal in the app's workflow and UI/UX",
    category: "Analysis & Review",
    fullText: `Great, now I want you to super carefully scrutinize every aspect of the application workflow and implementation and look for things that just seem sub-optimal or even wrong/mistaken to you, things that could very obviously be improved from a user-friendliness and intuitiveness standpoint, places where our UI/UX could be improved and polished to be slicker, more visually appealing, and more premium feeling and just ultra high quality, like Stripe-level apps.`,
  },
  {
    id: "apply_ubs",
    title: "Apply UBS",
    description: "Run UBS and fix every legitimate finding",
    category: "Analysis & Review",
    fullText: `Read about the ubs tool in AGENTS.md. Now run UBS and investigate and fix literally every single UBS issue once you determine (after reasoned consideration and close inspection) that it's legit.`,
  },
  // Coding & Development
  {
    id: "fix_bug",
    title: "Fix Bug",
    description: "Diagnose and fix the root cause of a bug, not a band-aid",
    category: "Coding & Development",
    params: "+ the bug details",
    fullText: `I want you to very carefully diagnose and then fix the root underlying cause of the bugs/errors shown here, but fix them FOR REAL, not a superficial "bandaid" fix! Here are the details:`,
    starred: true,
  },
  {
    id: "create_tests",
    title: "Create Tests",
    description: "Plan full unit and e2e coverage as beads",
    category: "Coding & Development",
    fullText: `Do we have full unit test coverage without using mocks/fake stuff? What about complete e2e integration test scripts with great, detailed logging? If not, then create a comprehensive and granular set of beads for all this with tasks, subtasks, and dependency structure overlaid with detailed comments.`,
  },
  {
    id: "leverage_tanstack_libraries",
    title: "Leverage TanStack Libraries",
    description: "Find code that a TanStack library would make simpler",
    category: "Coding & Development",
    fullText: `Ok I want you to look through the ENTIRE project and look for areas where, if we leveraged one of the many TanStack libraries (e.g., query, table, forms, etc), we could make part of the code much better, simpler, more performant, more maintainable, elegant, shorter, more reliable, etc.`,
  },
  {
    id: "build_ui_ux",
    title: "Build UI/UX",
    description: "Build world-class UI/UX components with the project's libraries",
    category: "Coding & Development",
    fullText: `I also want you to do a spectacular job building absolutely world-class UI/UX components, with an intense focus on making the most visually appealing, user-friendly, intuitive, slick, polished, "Stripe level" of quality UI/UX possible for this that leverages the good libraries that are already part of the project.`,
  },
  // Ensemble
  {
    id: "ensemble_list",
    title: "Ensemble Presets (Core)",
    description: "Propose a core lineup of agents for an ensemble",
    category: "Ensemble",
    fullText: `An ensemble is a few agents that each answer the same question from a different angle, which you then synthesize. herdr has no preset catalog, so propose one: run \`acfs agents list\` to see who is already running, then suggest a core lineup of two or three agents for the task at hand (agent kind and the angle each one takes). List larger or more expensive lineups separately and keep the main list core-only.`,
  },
  {
    id: "ensemble_run",
    title: "Ensemble Run (Pick Preset + Prompt)",
    description: "Start an ensemble and give each agent its angle",
    category: "Ensemble",
    params: "+ the question",
    fullText: `Pick the most appropriate lineup for the task at hand (see Ensemble Presets), then start it in this herdr workspace:
\`acfs agents spawn --claude <N> --codex <N> --no-prompt\`
Then send each new agent the question with its own angle:
\`acfs agents send --name <herdr name> "<question> Approach it as: <angle>"\`
If the question is missing, ask for it first.`,
  },
  {
    id: "ensemble_status",
    title: "Ensemble Status",
    description: "Summarize each ensemble agent's state and angle",
    category: "Ensemble",
    fullText: `Run \`acfs agents list\` and summarize the ensemble agents: each one's status (working, blocked, idle or done) and the angle it was given. Say whether all of them have finished and the ensemble is ready to synthesize. To wait for one, run \`herdr agent wait <herdr name>\` (without \`--until\`, it returns on idle, done or blocked).`,
  },
  {
    id: "ensemble_synthesize",
    title: "Ensemble Synthesize",
    description: "Collect the ensemble's answers and synthesize them",
    category: "Ensemble",
    fullText: `For each ensemble agent, collect its answer with \`herdr agent read <herdr name> --source recent --lines 200\`. Then synthesize: where the answers agree, where they disagree and why, and a recommendation. Summarize the result at a high level.`,
  },
  {
    id: "ensemble_modes_core",
    title: "Ensemble Modes (Core)",
    description: "Suggest the most useful angles for the current task",
    category: "Ensemble",
    fullText: `herdr has no list of reasoning modes. Suggest the three or four angles most useful for the current task (for example first principles, the user's view, an adversarial reviewer, the simplest thing that could work), one line each, to hand out to ensemble agents.`,
  },
  {
    id: "ensemble_modes_advanced",
    title: "Ensemble Modes (Advanced)",
    description: "Suggest further angles for a larger ensemble",
    category: "Ensemble",
    fullText: `Warning: advanced angles increase token spend (more agents, longer runs). If approved, suggest further angles for a larger ensemble (for example security, performance, failure modes and migration risk), and say which agent kind suits each.`,
  },
  // Documentation
  {
    id: "complete_docusaurus_site",
    title: "Complete Docusaurus Site",
    description: "Document the functionality the docs site doesn't cover yet",
    category: "Documentation",
    fullText: `Now I need you to look through the existing documentation in our docusaurus site here and look for the (many, many) instances of functionality in our project that are not described or explained at all yet (or explained inadequately) in the docusaurus site, and then create and expand the documentation in the site to cover these in an exhaustive, intuitive, helpful, useful, pragmatic way. Don't just make a dump of methods, parameters, etc. Add actually well-written narrative explaining what the stuff does, how it is organized, etc. to help another developer understand how it all works so that they can usefully contribute to the system.`,
  },
  {
    id: "improve_readme",
    title: "Improve README",
    description: "Check Agent Mail and learn the active agents' names",
    category: "Documentation",
    fullText: `Be sure to check your agent mail and to promptly respond if needed to any messages, and also acknowledge any contact requests; make sure you know the names of all active agents using the MCP Agent Mail system.`,
  },
  {
    id: "revise_readme",
    title: "Revise README",
    description: "Update the README as if it always read that way",
    category: "Documentation",
    fullText: `We need to revise the README too for these changes (don't write about these as "changes" however, make it read like it was always like that, we don't have any users yet!)`,
  },
  {
    id: "add_missing_features_to_readme",
    title: "Add Missing Features to README",
    description: "Add new detail on what was built, why and how",
    category: "Documentation",
    fullText: `What else can we put in there to make the README longer and more detailed about what we built, why it's useful, how it works, the algorithms/design principles used, etc. This is incremental NEW content, not replacement for what is there already.`,
  },
  // Planning & Workflow
  {
    id: "combine_plans_into_hybrid",
    title: "Combine Plans Into Hybrid",
    description: "Blend competing plans into one superior revision",
    category: "Planning & Workflow",
    params: "+ the competing plans",
    fullText: `I asked 3 competing LLMs to do the exact same thing and they came up with pretty different plans which you can read below. I want you to REALLY carefully analyze their plans with an open mind and be intellectually honest about what they did that's better than your plan. Then I want you to come up with the best possible revisions to your plan (you should simply update your existing document for your original plan with the revisions) that artfully and skillfully blends the "best of all worlds" to create a true, ultimate, superior hybrid version of the plan that best achieves our stated goals and will work the best in real-world practice to solve the problems we are facing and our overarching goals while ensuring the extreme success of the enterprise as best as possible; you should provide me with a complete series of git-diff style changes to your original plan to turn it into the new, enhanced, much longer and detailed plan that integrates the best of all the plans with every good idea included (you don't need to mention which ideas came from which models in the final revised enhanced plan):`,
  },
  {
    id: "improve_beads",
    title: "Improve Beads",
    description: "Check each bead and revise it while still in plan space",
    category: "Planning & Workflow",
    fullText: `Check over each bead super carefully-- are you sure it makes sense? Is it optimal? Could we change anything to make the system work better for users? If so, revise the beads. It's a lot easier and faster to operate in "plan space" before we start implementing these things!`,
  },
  {
    id: "turn_plan_into_beads",
    title: "Turn Plan Into Beads",
    description: "Turn a plan into self-documenting beads with dependencies",
    category: "Planning & Workflow",
    fullText: `OK so please take ALL of that and elaborate on it more and then create a comprehensive and granular set of beads for all this with tasks, subtasks, and dependency structure overlaid, with detailed comments so that the whole thing is totally self-contained and self-documenting (including relevant background, reasoning/justification, considerations, etc.-- anything we'd want our "future self" to know about the goals and intentions and thought process and how it serves the over-arching goals of the project.)`,
  },
  {
    id: "use_bv",
    title: "Use BV",
    description: "Find the most impactful bead with bv and start on it",
    category: "Planning & Workflow",
    fullText: `Use bv with the robot flags (see AGENTS.md for info on this) to find the most impactful bead(s) to work on next and then start on it. Remember to mark the beads appropriately and communicate with your fellow agents.`,
    starred: true,
  },
  {
    id: "next_bead",
    title: "Next Bead",
    description: "Pick the next useful bead and start coding",
    category: "Planning & Workflow",
    fullText: `Pick the next bead you can actually do usefully now and start coding on it immediately; communicate what you're working on to your fellow agents and mark beads appropriately as you work. And respond to any agent mail messages you've received.`,
  },
  {
    id: "work_on_your_beads",
    title: "Work on Your Beads",
    description: "Execute your remaining beads in the best order",
    category: "Planning & Workflow",
    fullText: `OK, so start systematically and methodically and meticulously and diligently executing those remaining beads tasks that you created in the optimal logical order! Don't forget to mark beads as you work on them.`,
  },
  {
    id: "do_all_of_it",
    title: "Do All Of It",
    description: "Do all of it, tracked in beads and Agent Mail",
    category: "Planning & Workflow",
    fullText: `OK, please do ALL of that now. Track work via br beads (no markdown TODO lists): create/claim/update/close beads as you go so nothing gets lost, and keep communicating via Agent Mail when you start/finish work.`,
  },
  // Git & Operations
  {
    id: "git_commit",
    title: "Git Commit",
    description: "Commit changes in logical groups with detailed messages",
    category: "Git & Operations",
    fullText: `Now, based on your knowledge of the project, commit all changed files now in a series of logically connected groupings with super detailed commit messages for each and then push. Take your time to do it right. Don't edit the code at all. Don't commit obviously ephemeral files. Use /effort max.`,
  },
  {
    id: "do_gh_flow",
    title: "Do GH Flow",
    description: "Commit, tag, release and watch GitHub Actions",
    category: "Git & Operations",
    fullText: `Do all the GitHub stuff: commit, deploy, create tag, bump version, release, monitor gh actions, compute checksums, etc.`,
  },
  // Agent Coordination
  {
    id: "default_new_agent",
    title: "Default New Agent",
    description: "The first prompt for a new agent: read, register, start",
    category: "Agent Coordination",
    fullText: `First read ALL of the AGENTS.md file and README.md file super carefully and understand ALL of both! Then use your code investigation agent mode to fully understand the code, and technical architecture and purpose of the project. Then register with MCP Agent Mail and introduce yourself to the other agents. Be sure to check your agent mail and to promptly respond if needed to any messages; then proceed meticulously with your next assigned beads, working on the tasks systematically and meticulously and tracking your progress via beads and agent mail messages. Don't get stuck in "communication purgatory" where nothing is getting done; be proactive about starting tasks that need to be done, but inform your fellow agents via messages when you do so and mark beads appropriately. When you're not sure what to do next, use the bv tool mentioned in AGENTS.md to prioritize the best beads to work on next; pick the next one that you can usefully work on and get started. Make sure to acknowledge all communication requests from other agents and that you are aware of all active agents and their names.`,
    starred: true,
  },
  {
    id: "check_and_respond_to_mail",
    title: "Check and Respond to Mail",
    description: "Read and acknowledge your unread Agent Mail",
    category: "Agent Coordination",
    fullText: `Be sure to check your agent mail and to promptly respond if needed to any messages, and also acknowledge any contact requests; make sure you know the names of all active agents using the MCP Agent Mail system.
Run \`acfs agents inbox --agent <your Agent Mail name>\` to read every unread message sent to you, oldest first, which also marks each one read; then acknowledge each message it lists as ack pending.`,
  },
  {
    id: "introduce_to_fellow_agents",
    title: "Introduce to Fellow Agents",
    description: "Read AGENTS.md, register with Agent Mail and say hello",
    category: "Agent Coordination",
    fullText: `Before doing anything else, read ALL of AGENTS.md, then register with MCP Agent Mail and introduce yourself to the other agents.`,
  },
  {
    id: "check_project_inbox",
    title: "Check Project Inbox",
    description: "Check the project inbox for new messages",
    category: "Agent Coordination",
    fullText: `Check the project inbox for any new messages from other agents or the human overseer.
Use Agent Mail's fetch_inbox tool, or run \`am mail inbox --project <project key> --agent <your Agent Mail name>\`, to see the full list of messages.`,
  },
  {
    id: "start_out_with_agent_mail",
    title: "Start Out With Agent Mail",
    description: "Check mail, then work your beads without stalling",
    category: "Agent Coordination",
    fullText: `Be sure to check your agent mail and to promptly respond if needed to any messages; then proceed meticulously with your next assigned beads, working on the tasks systematically and meticulously and tracking your progress via beads and agent mail messages. Don't get stuck in "communication purgatory" where nothing is getting done; be proactive about starting tasks that need to be done, but inform your fellow agents via messages when you do so and mark beads appropriately. When you're really not sure what to do, pick the next bead that you can usefully work on and get started. Make sure to acknowledge all communication requests from other agents and that you are aware of all active agents and their names. Use /effort max.`,
  },
  // Investigation
  {
    id: "read_agents_and_investigate",
    title: "Read Agents and Investigate",
    description: "Read AGENTS.md and README, then study the code",
    category: "Investigation",
    fullText: `First read ALL of the AGENTS.md file and README.md file super carefully and understand ALL of both! Then use your code investigation agent mode to fully understand the code, and technical architecture and purpose of the project.`,
  },
  {
    id: "reread_agents_md",
    title: "Reread AGENTS.md",
    description: "Reread AGENTS.md so it stays fresh",
    category: "Investigation",
    fullText: `Reread AGENTS.md so it's still fresh in your mind.`,
  },
  // Quick Commands
  {
    id: "effort_max",
    title: "Effort Max",
    description: "Ask for maximum effort",
    category: "Quick Commands",
    fullText: `Use /effort max.`,
  },
];

// ---------------------------------------------------------------------------
// Fuzzy-search helpers
// ---------------------------------------------------------------------------

interface FuzzyMatch {
  command: PaletteCommand;
  score: number;
  matchedIndices: number[];
}

function fuzzyMatch(query: string, text: string): { score: number; indices: number[] } {
  const lowerQuery = query.toLowerCase();
  const lowerText = text.toLowerCase();
  let qi = 0;
  let score = 0;
  const indices: number[] = [];
  let prevMatchIdx = -2;

  for (let ti = 0; ti < lowerText.length && qi < lowerQuery.length; ti++) {
    if (lowerText[ti] === lowerQuery[qi]) {
      indices.push(ti);
      score += 1;
      // Bonus for consecutive characters
      if (ti === prevMatchIdx + 1) {
        score += 2;
      }
      // Bonus for matching at word boundaries
      if (ti === 0 || lowerText[ti - 1] === " " || lowerText[ti - 1] === "-") {
        score += 3;
      }
      prevMatchIdx = ti;
      qi++;
    }
  }

  if (qi < lowerQuery.length) {
    return { score: 0, indices: [] };
  }

  return { score, indices };
}

function searchCommands(query: string, commands: PaletteCommand[]): FuzzyMatch[] {
  if (!query.trim()) return commands.map((c) => ({ command: c, score: 1, matchedIndices: [] }));

  const results: FuzzyMatch[] = [];
  for (const cmd of commands) {
    const titleMatch = fuzzyMatch(query, cmd.title);
    const descMatch = fuzzyMatch(query, cmd.description);
    const catMatch = fuzzyMatch(query, cmd.category);
    const bestScore = Math.max(titleMatch.score * 2, descMatch.score, catMatch.score);
    if (bestScore > 0) {
      const bestIndices =
        titleMatch.score * 2 >= descMatch.score && titleMatch.score * 2 >= catMatch.score
          ? titleMatch.indices
          : descMatch.score >= catMatch.score
            ? descMatch.indices
            : catMatch.indices;
      results.push({ command: cmd, score: bestScore, matchedIndices: bestIndices });
    }
  }
  results.sort((a, b) => b.score - a.score);
  return results;
}

// ---------------------------------------------------------------------------
// Highlighted text renderer
// ---------------------------------------------------------------------------
function HighlightedText({ text, indices }: { text: string; indices: number[] }) {
  if (indices.length === 0) return <>{text}</>;
  const indexSet = new Set(indices);
  return (
    <>
      {text.split("").map((char, i) =>
        indexSet.has(i) ? (
          <span key={i} className="text-primary font-semibold">
            {char}
          </span>
        ) : (
          <span key={i}>{char}</span>
        ),
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
// Mini terminal
// ---------------------------------------------------------------------------
function MiniTerminal({ lines, isTyping }: { lines: string[]; isTyping: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { amount: 0.15 });
  return (
    <div ref={ref} className="rounded-lg border border-white/[0.08] bg-black/40 overflow-hidden">
      <div className="flex items-center gap-1.5 border-b border-white/[0.06] bg-black/30 px-3 py-1.5">
        <div className="h-2 w-2 rounded-full bg-red-400/60" />
        <div className="h-2 w-2 rounded-full bg-yellow-400/60" />
        <div className="h-2 w-2 rounded-full bg-green-400/60" />
        <span className="ml-2 text-[10px] text-white/30 font-mono">command_palette.md</span>
      </div>
      <div className="p-3 font-mono text-xs leading-relaxed">
        {lines.map((line, i) => (
          <div key={i} className="text-white/60">
            {line.startsWith("$") ? (
              <>
                <span className="text-emerald-400">$</span>
                <span className="text-white/80">{line.slice(1)}</span>
              </>
            ) : line.startsWith(">") ? (
              <span className="text-sky-400">{line}</span>
            ) : line.startsWith("!") ? (
              <span className="text-amber-400">{line.slice(1)}</span>
            ) : (
              line
            )}
          </div>
        ))}
        {isTyping && (
          <motion.span
            animate={inView ? { opacity: [1, 0] } : { opacity: 1 }}
            transition={
              inView
                ? { duration: 0.8, repeat: Infinity, repeatType: "reverse" }
                : { duration: 0.2 }
            }
            className="inline-block h-3.5 w-1.5 bg-emerald-400/80 ml-0.5"
          />
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// INTERACTIVE PALETTE BROWSER (main component)
// ---------------------------------------------------------------------------
function InteractivePaletteBrowser() {
  const [searchQuery, setSearchQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [activeCommand, setActiveCommand] = useState<PaletteCommand | null>(null);
  const [copied, setCopied] = useState(false);
  const [sent, setSent] = useState(false);
  const [paletteOpen, setPaletteOpen] = useState(true);
  const [recentIds, setRecentIds] = useState<string[]>(() => [
    "fresh_review",
    "next_bead",
    "check_and_respond_to_mail",
  ]);
  const [terminalLines, setTerminalLines] = useState<string[]>(() => [
    `$ less ${PALETTE_PATH}`,
    `> ${PALETTE_COMMANDS.length} prompts across ${PALETTE_GROUPS.length} categories`,
    "",
  ]);
  const [isTerminalTyping, setIsTerminalTyping] = useState(false);
  const [activeCategoryFilter, setActiveCategoryFilter] = useState<string | null>(null);

  const searchInputRef = useRef<HTMLInputElement>(null);
  const listContainerRef = useRef<HTMLDivElement>(null);
  const copiedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const sentTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const typingTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const inView = useInView(rootRef, { amount: 0.15 });

  // Cleanup timers
  useEffect(() => {
    return () => {
      if (copiedTimerRef.current) clearTimeout(copiedTimerRef.current);
      if (sentTimerRef.current) clearTimeout(sentTimerRef.current);
      if (typingTimerRef.current) clearTimeout(typingTimerRef.current);
    };
  }, []);

  // Pre-filter by category, then fuzzy search
  const filteredResults = useMemo(() => {
    let pool = PALETTE_COMMANDS;
    if (activeCategoryFilter) {
      pool = pool.filter((c) => c.category === activeCategoryFilter);
    }
    return searchCommands(searchQuery, pool);
  }, [searchQuery, activeCategoryFilter]);

  // Group filtered results by category
  const groupedResults = useMemo(() => {
    const groups: Record<string, FuzzyMatch[]> = {};
    for (const r of filteredResults) {
      const cat = r.command.category;
      if (!groups[cat]) groups[cat] = [];
      groups[cat].push(r);
    }
    return groups;
  }, [filteredResults]);

  // Flat list for keyboard nav
  const flatResults = useMemo(() => {
    const flat: FuzzyMatch[] = [];
    for (const group of PALETTE_GROUPS) {
      const items = groupedResults[group.name];
      if (items) flat.push(...items);
    }
    return flat;
  }, [groupedResults]);

  // Clamp selected index
  useEffect(() => {
    if (selectedIndex >= flatResults.length) {
      const clamped = Math.max(0, flatResults.length - 1);
      setTimeout(() => setSelectedIndex(clamped), 0);
    }
  }, [flatResults.length, selectedIndex]);

  const recentCommands = useMemo(() => {
    return recentIds
      .map((id) => PALETTE_COMMANDS.find((c) => c.id === id))
      .filter((c): c is PaletteCommand => c !== undefined);
  }, [recentIds]);

  const findGroupForCommand = useCallback((cmd: PaletteCommand) => {
    return PALETTE_GROUPS.find((g) => g.name === cmd.category) ?? PALETTE_GROUPS[0];
  }, []);

  function selectCommand(cmd: PaletteCommand) {
    setActiveCommand(cmd);
    // Add to recent
    setRecentIds((prev) => {
      const next = [cmd.id, ...prev.filter((id) => id !== cmd.id)];
      return next.slice(0, 5);
    });
    // Terminal feedback
    setIsTerminalTyping(true);
    setTerminalLines((prev) => [
      ...prev.slice(-4),
      `> ### ${cmd.id} | ${cmd.title}`,
      `> Category: ${cmd.category}`,
      `> ${cmd.description}`,
      "",
    ]);
    if (typingTimerRef.current) clearTimeout(typingTimerRef.current);
    typingTimerRef.current = setTimeout(() => {
      setIsTerminalTyping(false);
      typingTimerRef.current = null;
    }, 800);
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIndex((i) => Math.min(i + 1, flatResults.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      const match = flatResults[selectedIndex];
      if (match) selectCommand(match.command);
    } else if (e.key === "Escape") {
      if (activeCommand) {
        setActiveCommand(null);
      } else if (searchQuery) {
        setSearchQuery("");
      }
    }
  }

  async function handleCopy() {
    if (!activeCommand) return;
    const ok = await copyTextToClipboard(activeCommand.fullText);
    if (!ok) return;
    setCopied(true);
    if (copiedTimerRef.current) clearTimeout(copiedTimerRef.current);
    copiedTimerRef.current = setTimeout(() => {
      setCopied(false);
      copiedTimerRef.current = null;
    }, 1500);
    setTerminalLines((prev) => [...prev.slice(-4), "!  Copied to clipboard", ""]);
  }

  function handleSend() {
    if (!activeCommand) return;
    setSent(true);
    if (sentTimerRef.current) clearTimeout(sentTimerRef.current);
    sentTimerRef.current = setTimeout(() => {
      setSent(false);
      sentTimerRef.current = null;
    }, 1500);
    setTerminalLines((prev) => [
      ...prev.slice(-4),
      `$ acfs agents send --all "<${activeCommand.id} prompt>"`,
      "> Sent to 3 agents",
      "!  Every agent took the prompt",
      "",
    ]);
  }

  // Compute global index offsets per group for highlighting
  const groupOffsets = useMemo(() => {
    const offsets: number[] = [];
    let offset = 0;
    for (const group of PALETTE_GROUPS) {
      offsets.push(offset);
      const items = groupedResults[group.name];
      if (items) offset += items.length;
    }
    return offsets;
  }, [groupedResults]);

  return (
    <div ref={rootRef} className="space-y-4">
      {/* Palette toggle bar */}
      <motion.div
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ type: "spring", stiffness: 200, damping: 25 }}
        className="flex items-center gap-3"
      >
        <motion.button
          whileHover={{ scale: 1.03 }}
          whileTap={{ scale: 0.97 }}
          transition={{ type: "spring", stiffness: 400, damping: 25 }}
          onClick={() => setPaletteOpen(!paletteOpen)}
          className="flex items-center gap-2 rounded-xl border border-white/[0.1] bg-white/[0.04] px-4 py-2.5 text-sm font-medium text-white/80 hover:bg-white/[0.08] hover:text-white transition-colors backdrop-blur-xl"
        >
          <Command className="h-4 w-4 text-primary" />
          <span>{paletteOpen ? "Close" : "Open"} Command Palette</span>
          <div className="ml-2 flex items-center gap-0.5">
            <kbd className="rounded border border-white/[0.12] bg-white/[0.06] px-1.5 py-0.5 font-mono text-[10px] text-white/40">
              Ctrl
            </kbd>
            <span className="text-white/20 text-[10px]">+</span>
            <kbd className="rounded border border-white/[0.12] bg-white/[0.06] px-1.5 py-0.5 font-mono text-[10px] text-white/40">
              K
            </kbd>
          </div>
        </motion.button>
        <span className="text-xs text-white/30">{PALETTE_COMMANDS.length} prompts available</span>
      </motion.div>

      <AnimatePresence mode="wait">
        {paletteOpen && (
          <motion.div
            key="palette"
            initial={{ opacity: 0, y: 20, scale: 0.98 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -10, scale: 0.98 }}
            transition={{ type: "spring", stiffness: 200, damping: 25 }}
            className="rounded-2xl border border-white/[0.08] bg-white/[0.02] backdrop-blur-xl overflow-hidden shadow-2xl shadow-black/40"
          >
            {/* Search bar */}
            <div className="relative border-b border-white/[0.08] bg-black/30">
              <div className="flex items-center gap-3 px-4 py-3">
                <Search className="h-4 w-4 text-white/30 shrink-0" />
                <input
                  ref={searchInputRef}
                  type="text"
                  value={searchQuery}
                  onChange={(e) => {
                    setSearchQuery(e.target.value);
                    setSelectedIndex(0);
                    setActiveCommand(null);
                  }}
                  onKeyDown={handleKeyDown}
                  placeholder="Search prompts... (type to filter)"
                  className="flex-1 bg-transparent text-sm text-white/90 placeholder:text-white/30 outline-none"
                />
                {searchQuery && (
                  <motion.button
                    initial={{ opacity: 0, scale: 0.8 }}
                    animate={{ opacity: 1, scale: 1 }}
                    transition={{ type: "spring", stiffness: 200, damping: 25 }}
                    onClick={() => {
                      setSearchQuery("");
                      setSelectedIndex(0);
                      searchInputRef.current?.focus();
                    }}
                    className="rounded-md p-0.5 text-white/30 hover:text-white/60 hover:bg-white/[0.06] transition-colors"
                  >
                    <X className="h-3.5 w-3.5" />
                  </motion.button>
                )}
                <div className="flex items-center gap-1 text-white/20">
                  <kbd className="rounded border border-white/[0.1] bg-white/[0.04] px-1 py-0.5 font-mono text-[10px]">
                    <CornerDownLeft className="h-2.5 w-2.5" />
                  </kbd>
                  <span className="text-[10px]">select</span>
                </div>
              </div>

              {/* Category filter pills */}
              <div className="flex gap-1.5 overflow-x-auto px-4 pb-2.5">
                <button
                  onClick={() => {
                    setActiveCategoryFilter(null);
                    setSelectedIndex(0);
                  }}
                  className={`shrink-0 rounded-full px-2.5 py-1 text-[10px] font-medium transition ${
                    activeCategoryFilter === null
                      ? "bg-white/[0.12] text-white"
                      : "bg-white/[0.04] text-white/40 hover:bg-white/[0.08] hover:text-white/60"
                  }`}
                >
                  All
                </button>
                {PALETTE_GROUPS.map((group) => (
                  <button
                    key={group.name}
                    type="button"
                    aria-label={group.name}
                    aria-pressed={activeCategoryFilter === group.name}
                    onClick={() => {
                      setActiveCategoryFilter(
                        activeCategoryFilter === group.name ? null : group.name,
                      );
                      setSelectedIndex(0);
                    }}
                    className={`flex shrink-0 items-center gap-1 rounded-full px-2.5 py-1 text-[10px] font-medium transition ${
                      activeCategoryFilter === group.name
                        ? `${group.badgeBg} ${group.badgeText}`
                        : "bg-white/[0.04] text-white/40 hover:bg-white/[0.08] hover:text-white/60"
                    }`}
                  >
                    {group.icon}
                    <span className="hidden sm:inline">{group.name}</span>
                  </button>
                ))}
              </div>
            </div>

            {/* Main content area */}
            <div className="flex flex-col lg:flex-row min-h-[420px] max-h-[600px]">
              {/* Command list */}
              <div
                ref={listContainerRef}
                className="flex-1 overflow-y-auto border-b border-white/[0.08] lg:border-b-0 lg:border-r lg:max-w-[420px]"
              >
                {/* Recently Used section */}
                {!searchQuery && !activeCategoryFilter && recentCommands.length > 0 && (
                  <div className="px-3 pt-3 pb-1">
                    <div className="flex items-center gap-2 px-2 pb-2">
                      <Clock className="h-3 w-3 text-white/25" />
                      <span className="text-[10px] font-medium uppercase tracking-wider text-white/25">
                        Recently Used
                      </span>
                    </div>
                    <div className="space-y-0.5">
                      {recentCommands.map((cmd) => {
                        const group = findGroupForCommand(cmd);
                        return (
                          <motion.button
                            key={`recent-${cmd.id}`}
                            whileHover={{ x: 2 }}
                            transition={{ type: "spring", stiffness: 200, damping: 25 }}
                            onClick={() => selectCommand(cmd)}
                            className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${
                              activeCommand?.id === cmd.id
                                ? "bg-white/[0.08]"
                                : "hover:bg-white/[0.04]"
                            }`}
                          >
                            <div className={`${group.badgeText}`}>{group.icon}</div>
                            <span className="text-xs font-medium text-white/70 truncate">
                              {cmd.title}
                            </span>
                          </motion.button>
                        );
                      })}
                    </div>
                    <div className="mx-2 my-2 h-px bg-white/[0.06]" />
                  </div>
                )}

                {/* Grouped command list */}
                <div className="px-3 py-2 space-y-1">
                  {PALETTE_GROUPS.map((group, groupIdx) => {
                    const items = groupedResults[group.name];
                    if (!items || items.length === 0) return null;
                    return (
                      <div key={group.name}>
                        <div className="flex items-center gap-2 px-2 py-1.5">
                          <span className={group.badgeText}>{group.icon}</span>
                          <span className="text-[10px] font-medium uppercase tracking-wider text-white/25">
                            {group.name}
                          </span>
                          <span className="text-[10px] text-white/15">{items.length}</span>
                        </div>
                        <AnimatePresence mode="popLayout">
                          <div className="space-y-0.5">
                            {items.map((match, itemIdx) => {
                              const currentGlobalIdx = groupOffsets[groupIdx] + itemIdx;
                              const isSelected = currentGlobalIdx === selectedIndex;
                              const isActive = activeCommand?.id === match.command.id;
                              return (
                                <motion.button
                                  key={match.command.id}
                                  initial={{ opacity: 0, x: -8 }}
                                  animate={{ opacity: 1, x: 0 }}
                                  transition={{ type: "spring", stiffness: 200, damping: 25 }}
                                  whileHover={{ x: 2 }}
                                  onClick={() => {
                                    selectCommand(match.command);
                                    setSelectedIndex(currentGlobalIdx);
                                  }}
                                  className={`group/item flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition ${
                                    isActive
                                      ? "bg-white/[0.08] border border-white/[0.12]"
                                      : isSelected
                                        ? "bg-white/[0.05] border border-white/[0.08]"
                                        : "border border-transparent hover:bg-white/[0.04]"
                                  }`}
                                >
                                  {/* Star indicator */}
                                  {match.command.starred && (
                                    <Star className="h-2.5 w-2.5 text-amber-400/60 fill-amber-400/40 shrink-0" />
                                  )}
                                  <div className="flex-1 min-w-0">
                                    <div className="flex items-center gap-2">
                                      <span className="text-xs font-medium text-white/80 truncate">
                                        {searchQuery ? (
                                          <HighlightedText
                                            text={match.command.title}
                                            indices={
                                              fuzzyMatch(searchQuery, match.command.title).indices
                                            }
                                          />
                                        ) : (
                                          match.command.title
                                        )}
                                      </span>
                                      {match.command.params && (
                                        <span className="shrink-0 rounded bg-white/[0.06] px-1.5 py-0.5 font-mono text-[10px] text-white/30">
                                          {match.command.params}
                                        </span>
                                      )}
                                    </div>
                                    <p className="mt-0.5 truncate text-xs text-white/35">
                                      {match.command.description}
                                    </p>
                                  </div>
                                  <ChevronRight
                                    className={`h-3.5 w-3.5 shrink-0 transition ${
                                      isActive
                                        ? "text-primary"
                                        : "text-white/15 group-hover/item:text-white/30"
                                    }`}
                                  />
                                </motion.button>
                              );
                            })}
                          </div>
                        </AnimatePresence>
                      </div>
                    );
                  })}

                  {/* Empty state */}
                  {flatResults.length === 0 && (
                    <motion.div
                      initial={{ opacity: 0 }}
                      animate={{ opacity: 1 }}
                      transition={{ type: "spring", stiffness: 200, damping: 25 }}
                      className="flex flex-col items-center justify-center py-12 text-center"
                    >
                      <Search className="h-8 w-8 text-white/10 mb-3" />
                      <p className="text-sm text-white/30">
                        No prompts match &quot;{searchQuery}&quot;
                      </p>
                      <p className="text-xs text-white/20 mt-1">Try a different search term</p>
                    </motion.div>
                  )}
                </div>
              </div>

              {/* Command detail / preview panel */}
              <div className="flex-1 flex flex-col min-h-[300px]">
                <AnimatePresence mode="wait">
                  {activeCommand ? (
                    <motion.div
                      key={activeCommand.id}
                      initial={{ opacity: 0, x: 16 }}
                      animate={{ opacity: 1, x: 0 }}
                      exit={{ opacity: 0, x: -8 }}
                      transition={{ type: "spring", stiffness: 200, damping: 25 }}
                      className="flex flex-col h-full"
                    >
                      {/* Command header */}
                      <div className="border-b border-white/[0.06] px-5 py-4">
                        <div className="flex items-center gap-2.5 mb-2">
                          <span className={`${findGroupForCommand(activeCommand).badgeText}`}>
                            {findGroupForCommand(activeCommand).icon}
                          </span>
                          <span
                            className={`rounded-full px-2 py-0.5 text-[10px] font-medium ${findGroupForCommand(activeCommand).badgeBg} ${findGroupForCommand(activeCommand).badgeText}`}
                          >
                            {activeCommand.category}
                          </span>
                          {activeCommand.starred && (
                            <Star className="h-3 w-3 text-amber-400/60 fill-amber-400/40" />
                          )}
                        </div>
                        <h3 className="text-base font-bold text-white">{activeCommand.title}</h3>
                        <p className="mt-1 text-xs text-white/50">{activeCommand.description}</p>

                        {/* Palette key */}
                        <div className="mt-3 flex items-center gap-2">
                          <Keyboard className="h-3.5 w-3.5 text-white/25" />
                          <span className="text-[10px] text-white/25 mr-1">Key:</span>
                          <motion.kbd
                            initial={{ opacity: 0, y: 4 }}
                            animate={{ opacity: 1, y: 0 }}
                            transition={{ type: "spring", stiffness: 200, damping: 25 }}
                            className="inline-flex h-7 max-w-full items-center truncate rounded-md border border-white/[0.15] bg-gradient-to-b from-white/[0.08] to-white/[0.03] px-2 font-mono text-xs font-medium text-white/60 shadow-sm shadow-black/20"
                          >
                            {activeCommand.id}
                          </motion.kbd>
                        </div>
                      </div>

                      {/* Execution preview */}
                      <div className="flex-1 overflow-auto px-5 py-4">
                        <div className="flex items-center gap-2 mb-2">
                          <Hash className="h-3 w-3 text-white/25" />
                          <span className="text-[10px] font-medium uppercase tracking-wider text-white/25">
                            Execution Preview
                          </span>
                        </div>
                        <div className="rounded-lg border border-white/[0.08] bg-black/30 p-4 overflow-auto">
                          <pre className="whitespace-pre-wrap font-mono text-xs leading-relaxed text-white/65">
                            {activeCommand.fullText}
                          </pre>
                        </div>

                        {/* Parameter hint */}
                        {activeCommand.params && (
                          <motion.div
                            initial={{ opacity: 0, y: 8 }}
                            animate={{ opacity: 1, y: 0 }}
                            transition={{
                              type: "spring",
                              stiffness: 200,
                              damping: 25,
                              delay: 0.15,
                            }}
                            className="mt-3 flex items-center gap-2 rounded-lg border border-white/[0.06] bg-white/[0.02] px-3 py-2"
                          >
                            <Lightbulb className="h-3.5 w-3.5 text-amber-400/60 shrink-0" />
                            <span className="text-[11px] text-white/40">
                              Accepts parameter:{" "}
                              <code className="rounded bg-white/[0.06] px-1 py-0.5 font-mono text-[10px] text-white/60">
                                {activeCommand.params}
                              </code>
                            </span>
                          </motion.div>
                        )}
                      </div>

                      {/* Action buttons */}
                      <div className="border-t border-white/[0.06] px-5 py-3">
                        <div className="flex gap-2">
                          <motion.button
                            whileHover={{ scale: 1.02 }}
                            whileTap={{ scale: 0.98 }}
                            transition={{ type: "spring", stiffness: 200, damping: 25 }}
                            onClick={handleSend}
                            className="relative flex flex-1 items-center justify-center gap-2 rounded-lg bg-gradient-to-r from-primary/80 to-violet-500/80 px-4 py-2.5 text-xs font-semibold text-white shadow-lg shadow-primary/20 hover:from-primary hover:to-violet-500 transition overflow-hidden"
                          >
                            {sent && (
                              <motion.div
                                initial={{ scale: 0, opacity: 0.6 }}
                                animate={{ scale: 4, opacity: 0 }}
                                transition={{ type: "spring", stiffness: 200, damping: 20 }}
                                className="absolute h-8 w-8 rounded-full bg-white/30"
                              />
                            )}
                            <Send className="h-3.5 w-3.5" />
                            <span className="relative">
                              {sent ? "Sent to All Agents!" : "Send to All Agents"}
                            </span>
                          </motion.button>
                          <motion.button
                            whileHover={{ scale: 1.02 }}
                            whileTap={{ scale: 0.98 }}
                            transition={{ type: "spring", stiffness: 200, damping: 25 }}
                            onClick={handleCopy}
                            className="flex items-center gap-1.5 rounded-lg border border-white/[0.1] bg-white/[0.04] px-4 py-2.5 text-xs font-medium text-white/70 hover:bg-white/[0.08] hover:text-white transition-colors"
                          >
                            {copied ? (
                              <Check className="h-3.5 w-3.5 text-emerald-400" />
                            ) : (
                              <Copy className="h-3.5 w-3.5" />
                            )}
                            <span>{copied ? "Copied!" : "Copy"}</span>
                          </motion.button>
                        </div>
                      </div>
                    </motion.div>
                  ) : (
                    <motion.div
                      key="empty-preview"
                      initial={{ opacity: 0 }}
                      animate={{ opacity: 1 }}
                      exit={{ opacity: 0 }}
                      transition={{ type: "spring", stiffness: 200, damping: 25 }}
                      className="flex flex-col items-center justify-center h-full px-8 py-12"
                    >
                      <motion.div
                        animate={inView ? { y: [0, -6, 0] } : { y: 0 }}
                        transition={
                          inView
                            ? {
                                duration: 3,
                                repeat: Infinity,
                                repeatType: "loop",
                                ease: "easeInOut",
                              }
                            : { duration: 0.2 }
                        }
                        className="mb-4"
                      >
                        <div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-gradient-to-br from-primary/10 to-violet-500/10 border border-white/[0.06]">
                          <Command className="h-7 w-7 text-white/20" />
                        </div>
                      </motion.div>
                      <p className="text-sm font-medium text-white/30 text-center">
                        Select a prompt to preview
                      </p>
                      <p className="mt-1 text-xs text-white/20 text-center">
                        Use arrow keys or click to browse
                      </p>
                      <div className="mt-4 flex items-center gap-3 text-white/60">
                        <div className="flex items-center gap-1">
                          <kbd className="rounded border border-white/[0.08] bg-white/[0.04] px-1.5 py-0.5 font-mono text-[10px]">
                            &uarr;
                          </kbd>
                          <kbd className="rounded border border-white/[0.08] bg-white/[0.04] px-1.5 py-0.5 font-mono text-[10px]">
                            &darr;
                          </kbd>
                          <span className="text-[10px] ml-0.5">navigate</span>
                        </div>
                        <div className="flex items-center gap-1">
                          <kbd className="rounded border border-white/[0.08] bg-white/[0.04] px-1.5 py-0.5 font-mono text-[10px]">
                            Enter
                          </kbd>
                          <span className="text-[10px] ml-0.5">select</span>
                        </div>
                        <div className="flex items-center gap-1">
                          <kbd className="rounded border border-white/[0.08] bg-white/[0.04] px-1.5 py-0.5 font-mono text-[10px]">
                            Esc
                          </kbd>
                          <span className="text-[10px] ml-0.5">back</span>
                        </div>
                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            </div>

            {/* Mini terminal footer */}
            <div className="border-t border-white/[0.06]">
              <MiniTerminal lines={terminalLines} isTyping={isTerminalTyping} />
            </div>

            {/* Status bar */}
            <div className="flex items-center justify-between border-t border-white/[0.06] bg-black/20 px-4 py-1.5">
              <div className="flex items-center gap-3 text-[10px] text-white/25">
                <span className="flex items-center gap-1">
                  <Layers className="h-2.5 w-2.5" />
                  {PALETTE_GROUPS.length} categories
                </span>
                <span className="flex items-center gap-1">
                  <Hash className="h-2.5 w-2.5" />
                  {flatResults.length} / {PALETTE_COMMANDS.length} prompts
                </span>
              </div>
              <div className="flex items-center gap-2 text-[10px] text-white/25">
                <span className="flex items-center gap-1">
                  <Star className="h-2.5 w-2.5 text-amber-400/40 fill-amber-400/30" />
                  {PALETTE_COMMANDS.filter((c) => c.starred).length} starred
                </span>
                <span>herdr</span>
              </div>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
