# Codex

This directory is tracked repo-local Codex configuration.

- `config.toml` makes Codex use the repository's `CLAUDE.md` files as its shared
  project instruction source.
- `hooks.json` wires Codex `PreToolUse` events to the same guard scripts used by
  Claude Code under `.claude/hooks/`. It also wires `Stop` to the shared learning
  nudge, but that hook is written against Claude's Stop payload
  (`transcript_path`, `session_id`, `stop_hook_active`). It is best-effort on
  Codex: if Codex's Stop event does not supply a readable `transcript_path`, the
  hook no-ops silently (exit 0). Treat the skill + `CLAUDE.md` bar as the
  reliable capture path for Codex until the payload is verified.
- Runtime Codex state still lives in `~/.codex`; `hosts/main/backups.nix`
  already includes that directory in workstation backups.
