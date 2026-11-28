---
name: delegate-research
description: Use when a task needs web research (current versions, upstream behavior, what other projects do, comparing tools) that would fill your context with search results; hands it to Codex gpt-6.2-astra with live web search and reads back only the cited conclusion.
---

# Delegate Research

`gpt-6.2-astra` on Codex is strong at web research and runs on a separate
subscription. Sending the research there keeps search results out of your
context and spreads usage across both plans. If you are Codex, do the research
yourself with web search on; this skill is for Claude.

## How

Write a self-contained brief: the question, why it matters, what is already
known, what a good answer contains, and that every claim needs a source URL.

```sh
codex --search exec -m gpt-6.2-astra -s read-only --ephemeral --skip-git-repo-check \
  -C "$SCRATCH" -o "$SCRATCH/research.md" "$BRIEF" >"$SCRATCH/research.log" 2>&1
cat "$SCRATCH/research.md"
```

For a long brief, pipe it on stdin and pass `-` as the prompt. Allow several
minutes; run it in the background when you have other work.

## Brief checklist

- The exact question, plus versions, dates and constraints (NixOS unstable,
  this flake's inputs, today's date).
- What to compare and the criteria that decide it.
- The output: a short answer first, then the evidence, with a URL for each
  claim, and what is uncertain or could not be verified.

## Using the answer

- Treat it as research notes from another model: check any claim you act on
  against its source, especially versions, dates and option names.
- Cite the sources to the user.
- Never send secrets, private hostnames, tailnet names or personal data in the
  brief.
