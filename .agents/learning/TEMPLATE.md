---
# Machine-routing fields. The reviewer reads these.
date: YYYY-MM-DD        # when captured
expires: YYYY-MM-DD     # date + 30d; reviewer rejects if still unpromoted past this
status: open            # open | promoted | rejected
agent: claude | codex   # who captured it
---

# <one-line title>

**Lesson.** The reusable thing learned, in one or two sentences. Stated as a
rule a future agent could act on — not a story about this session.

**Evidence.** A verifiable pointer, not a vibe: a commit hash, a `file:line`, a
failing-test/validation output, or a direct user correction (quote it). If you
cannot point to evidence, do not file the candidate.

**When to apply.** The concrete trigger that should surface this lesson — the
file, command, host, or task shape that makes it relevant.

**Best form.** The strongest viable destination from the promotion hierarchy
(assertion/test > hook > skill > prose). If you propose anything weaker than an
executable check, justify in one line why a stronger form is not possible.

**Proposed destination.** A concrete target path, e.g. `lib/invariants.nix`,
`tests/lib/invariants.nix`, `.claude/hooks/guard-edits.sh`,
`.agents/skills/<name>/SKILL.md`, or `CLAUDE.md`.

**Risk if wrong.** Blast radius if this lesson is bad, over-broad, or goes
stale — what a future agent would do incorrectly by trusting it.
