# Codex

This directory is tracked repo-local Codex configuration.

- `config.toml` makes Codex use the repository's `CLAUDE.md` files as its shared
  project instruction source.
- `hooks.json` wires Codex `PreToolUse` events to the same guard scripts used by
  Claude Code under `.claude/hooks/`.
- Runtime Codex state still lives in `~/.codex`; `hosts/main/backups.nix`
  already includes that directory in workstation backups.

