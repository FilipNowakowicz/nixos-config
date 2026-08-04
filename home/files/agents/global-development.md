# Global development preferences

## Git commits

Do not add `Co-Authored-By`, agent-session, or tool-attribution trailers to
commit messages. Do not mention Claude, Anthropic, Codex, OpenAI, Gemini, or
other agent tooling in commit messages, PR descriptions, or PR bodies. Commits
should show only the human author unless repository-specific instructions say
otherwise.

## Python projects

Unless a repository explicitly declares a different workflow, use `uv` for
Python interpreter, environment, dependency, tool, and command management:

- Use `uv sync` to create or update the project `.venv` from `pyproject.toml`
  and its lockfile.
- Use `uv run <command>` for Python, tests, scripts, formatters, linters, and
  other project commands. Do not require manual virtualenv activation.
- Use a uv-managed Python interpreter. Do not build a project environment from
  whichever global `python` or `pip` happens to be on `PATH`.
- Keep project dependency metadata portable. `pyproject.toml`, `uv.lock`, and
  an optional `.python-version` are cross-platform Python files; keep `.venv/`
  ignored.
- Do not add `flake.nix`, `shell.nix`, `.envrc`, or ad-hoc `nix-shell`/
  `nix develop` commands solely to supply Python dependencies. NixOS runtime
  compatibility belongs in `~/nix`, not in otherwise portable Python repos.
- Do not silently migrate a repository that intentionally uses Poetry, Conda,
  a project-local Nix shell, or another documented workflow. Repository-local
  instructions and existing project policy take precedence.

If a native Python wheel fails to load on NixOS, diagnose the missing shared
library and fix the centralized `nix-ld`/workstation configuration when
appropriate instead of adding machine-specific linker paths to the project.
