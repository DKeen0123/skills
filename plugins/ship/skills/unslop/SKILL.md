---
name: unslop
description: |
  Detect and remove AI slop — in UI (generic AI-generated visual patterns) and
  in prose (AI vocabulary, filler phrases, corporate hedging). Use when asked to
  "unslop", "de-slop", "remove the AI slop", "this looks/sounds AI-generated",
  "make this not look like a template", or when auditing a page or document for
  generic AI patterns. Works in two modes: audit (report findings) and fix
  (rewrite/restyle in place).
---

# unslop — AI Slop Detection & Removal

Two modes. If the user pointed at a UI/page/component, run the **visual** checklist.
If they pointed at prose (docs, PR descriptions, marketing copy, UI microcopy),
run the **writing** checklist. If unclear, ask which — or both. When invoked
by another skill, run the checklist the caller names, or both if it names
none.

Default to **audit first**: list findings with file:line references, then fix.
When fixing, make each fix a focused edit; don't restyle things that weren't slop.

The governing test: **would a human at a respected studio ever ship this?**

## Visual slop — the blacklist

Ten anti-patterns. Each one found is a finding.

1. **Purple/violet/indigo gradient backgrounds** or blue-to-purple color schemes.
2. **The 3-column feature grid**: icon-in-colored-circle + bold title + 2-line
   description, repeated 3× symmetrically. The most recognizable AI layout.
3. **Icons in colored circles** as section decoration (SaaS starter template look).
4. **Centered everything** — `text-align: center` on all headings, descriptions, cards.
5. **Uniform bubbly border-radius** — the same large radius on every element.
6. **Decorative blobs, floating circles, wavy SVG dividers.** If a section feels
   empty, it needs better content, not decoration.
7. **Emoji as design elements** — rockets in headings, emoji as bullet points.
8. **Colored left-border on cards** (`border-left: 3px solid <accent>`).
9. **Generic hero copy** — "Welcome to [X]", "Unlock the power of…",
   "Your all-in-one solution for…".
10. **Cookie-cutter section rhythm** — hero → 3 features → testimonials →
    pricing → CTA, every section the same height.

When fixing visual slop, use the project's existing component library (per
its `CLAUDE.md` or equivalent) rather than hand-rolled markup, and verify the
result visually with rodney/showboat (see `ship:rodney-tips`) before claiming it's
fixed.

## Microcopy slop

- Button labels generic ("Continue", "Submit") where specific works ("Save API key").
- Empty states that just say "No items." — need a message + action.
- Error messages that state the error without what to do next.
- Passive voice where active is shorter ("Install the CLI", not "The CLI will
  be installed").
- Placeholder/lorem text left visible.

## Writing slop — vocabulary and phrasing

Flag and rewrite; don't just delete — replace with the concrete thing the
sentence was avoiding saying.

**AI vocabulary** (each occurrence is a finding): delve, crucial, robust,
comprehensive, nuanced, multifaceted, furthermore, moreover, additionally,
pivotal, landscape, tapestry, underscore, foster, showcase, intricate, vibrant,
seamless, leverage (as a verb), utilize, elevate, empower, streamline,
game-changer, cutting-edge, "in today's fast-paced world".

**Banned phrases**: "here's the kicker", "here's the thing", "plot twist",
"let me break this down", "the bottom line", "make no mistake", "can't stress
this enough", "it's important to note", "it's worth noting", "at the end of
the day".

**Structural tells**:
- Every paragraph the same length; every list exactly three items.
- Rule-of-three sentence padding ("fast, reliable, and scalable") where one
  precise adjective would do.
- Hedged conclusions ("this might potentially help") where the writer knows
  the answer.
- Summary paragraphs that restate what was just said.
- Headings that are labels for the obvious ("Conclusion", "Overview") instead
  of carrying information.

**Rewrite direction**:
- Name specifics: real file names, real numbers, real commands. "This queries
  N+1 — ~200ms per page load at 50 items", not "this might be slow".
- Short paragraphs; vary rhythm. One-sentence paragraphs are allowed.
- Direct judgments: "well-designed" or "this is a mess" — don't dance.
- Cut throat-clearing; start with the point.
- End with the action, not a summary.

## Output

Audit mode: a findings list — `file:line` (or selector/section for UI), the
pattern matched, and the proposed replacement. Fix mode: apply the edits, then
list what changed. Either way, finish with a one-line verdict: how sloppy was
it, and what single change mattered most.
