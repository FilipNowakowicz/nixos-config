# Global development preferences

## Git commits

Do not add `Co-Authored-By`, agent-session, or tool-attribution trailers to
commit messages. Do not mention Claude, Anthropic, Codex, OpenAI, Gemini, or
other agent tooling in commit messages, PR descriptions, or PR bodies. Commits
should show only the human author unless repository-specific instructions say
otherwise.

## Git worktrees

Put linked worktrees under `~/.local/share/worktrees/<repo>/<name>` (for
example `git worktree add ~/.local/share/worktrees/nix/fix-foo -b fix-foo`),
not in `/tmp`, inside the repository, or in a visible folder in `~`:

- `/tmp` is tmpfs on NixOS workstations and is wiped on reboot, so
  uncommitted work there is lost. It does not remove stale branches either,
  because branches live in the primary checkout's `.git`.
- Commit WIP before long-running validation in a worktree.
- Clean up after yourself: once the branch is merged and the merge is
  verified, `git worktree remove <path>` and delete the merged branch. Never
  remove a worktree another session is still using, or one with uncommitted
  changes you did not make.

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

## Long CPU-heavy jobs

On `main`, run long CPU-bound work (calibrations, simulations, parameter
sweeps, large test matrices: anything over a few minutes at high CPU) on the
on-demand `gcp-builder` VM with `on-worker`, not on the laptop. It has 14 vCPUs,
shared with Nix builds for the fleet, which run at a lower CPU priority.
Keep short commands and quick tests local, since starting the VM adds about a
minute.

- `on-worker run -n NAME -- CMD...` syncs the current Git checkout (tracked plus
  untracked, non-ignored files) and starts CMD detached there. Use `-i PATH`
  for gitignored inputs. Python projects use `uv run` there as here.
- `on-worker logs -f NAME` follows a job and exits with its status;
  `on-worker status` lists jobs; `on-worker pull PATH...` copies results back.
- A finished job sends an ntfy notification. The VM powers itself off when
  idle, so never leave a shell open on it to keep it alive.
