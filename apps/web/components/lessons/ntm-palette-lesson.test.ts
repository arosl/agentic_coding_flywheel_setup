/**
 * Palette lesson tests
 *
 * The palette browser in the ntm-palette lesson shows the prompts of the
 * palette ACFS installs (acfs/onboard/docs/ntm/command_palette.md). These
 * tests parse that file and require the browser to hold the same prompts, in
 * the same order and categories, so a palette sync that adds, renames or
 * rewords a prompt fails here until the lesson follows it.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { getLessonBySlug, isReferenceLesson, LESSONS } from "../../lib/lessons";
import { PALETTE_COMMANDS, PALETTE_GROUPS, PALETTE_PATH } from "./ntm-palette-lesson";

const PALETTE_FILE = join(
  import.meta.dir,
  "..",
  "..",
  "..",
  "..",
  "acfs",
  "onboard",
  "docs",
  "ntm",
  "command_palette.md",
);

interface ParsedPrompt {
  id: string;
  title: string;
  category: string;
  text: string;
}

// Same format the palette documents: "## Category", then "### key | Label"
// followed by the prompt text. Trailing spaces on a line don't count.
function parsePalette(source: string): ParsedPrompt[] {
  const prompts: ParsedPrompt[] = [];
  let category = "";
  let current: ParsedPrompt | null = null;
  const flush = () => {
    if (current) {
      current.text = current.text.trim();
      prompts.push(current);
      current = null;
    }
  };
  for (const raw of source.split("\n")) {
    const line = raw.trimEnd();
    const heading = /^### ([a-z0-9_]+) \| (.+)$/.exec(line);
    if (line.startsWith("## ")) {
      flush();
      category = line.slice(3);
    } else if (heading) {
      flush();
      current = { id: heading[1], title: heading[2], category, text: "" };
    } else if (current) {
      current.text += `${line}\n`;
    }
  }
  flush();
  return prompts;
}

const parsed = parsePalette(readFileSync(PALETTE_FILE, "utf8"));

describe("palette browser matches command_palette.md", () => {
  test("the palette file parses into prompts", () => {
    expect(parsed.length).toBeGreaterThan(30);
  });

  test("same prompt keys in the same order", () => {
    expect(PALETTE_COMMANDS.map((c) => c.id)).toEqual(parsed.map((p) => p.id));
  });

  test("same labels and categories", () => {
    expect(PALETTE_COMMANDS.map((c) => [c.id, c.title, c.category])).toEqual(
      parsed.map((p) => [p.id, p.title, p.category]),
    );
  });

  test("same prompt text", () => {
    for (const [i, prompt] of parsed.entries()) {
      expect({ id: PALETTE_COMMANDS[i]?.id, text: PALETTE_COMMANDS[i]?.fullText }).toEqual({
        id: prompt.id,
        text: prompt.text,
      });
    }
  });

  test("one browser group per palette category, in order", () => {
    const categories = [...new Set(parsed.map((p) => p.category))];
    expect(PALETTE_GROUPS.map((g) => g.name)).toEqual(categories);
  });

  test("the lesson names the path ACFS installs the palette to", () => {
    expect(PALETTE_PATH).toBe("~/.acfs/onboard/docs/ntm/command_palette.md");
  });
});

describe("restored herdr lessons", () => {
  test("ntm-core and ntm-palette sit at ids 7 and 8 and are reference lessons", () => {
    expect(getLessonBySlug("ntm-core")?.id).toBe(7);
    expect(getLessonBySlug("ntm-palette")?.id).toBe(8);
    expect(isReferenceLesson(7)).toBe(true);
    expect(isReferenceLesson(8)).toBe(true);
  });

  test("lesson ids stay contiguous from 0", () => {
    expect(LESSONS.map((l) => l.id)).toEqual(LESSONS.map((_, i) => i));
  });
});
