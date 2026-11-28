{ lib, pkgs }:
hm:
let
  files = hm.home.file;
  targets = [
    ".claude/CLAUDE.md"
    ".codex/AGENTS.md"
    ".gemini/GEMINI.md"
  ];
  enabledFile = name: builtins.hasAttr name files && files.${name}.enable;
  configFile = name: "${hm.xdg.configHome}/uv/${name}";
  policySources = map (name: toString files.${name}.source) targets;
in
assert lib.assertMsg (lib.any (
  p: lib.getName p == "uv"
) hm.home.packages) "Home Manager must install uv";
# python3 on PATH must be the uv shim, never a Nix Python that bypasses the
# managed-interpreter policy.
assert lib.assertMsg (
  lib.any (p: lib.getName p == "python3") hm.home.packages
  && !(lib.any (
    p: (p.pname or "") == "python3" || lib.hasPrefix "python3-" (p.name or "")
  ) hm.home.packages)
) "python3 on PATH must be the uv shim from python-development.nix";
assert lib.assertMsg (lib.all enabledFile (
  targets
  ++ map configFile [
    "uv.toml"
    ".python-version"
  ]
)) "Home Manager must install the uv configuration, Python pin and global instructions";
assert lib.assertMsg (
  lib.length (lib.unique policySources) == 1
) "Global instructions must share one source";
assert lib.assertMsg (
  hm.home.activation ? claudeNoAttribution
) "Missing attribution activation step";
pkgs.runCommand "python-development-rendered-files"
  {
    uvConfig = files.${configFile "uv.toml"}.source;
    pythonPin = files.${configFile ".python-version"}.source;
    instructions = lib.head policySources;
  }
  ''
    ${pkgs.python3}/bin/python - <<'PY'
    import os
    import tomllib
    from pathlib import Path

    with open(os.environ["uvConfig"], "rb") as config:
        assert tomllib.load(config).get("python-preference") == "only-managed", "uv must use managed Python"
    assert Path(os.environ["pythonPin"]).read_text().strip() == "3.12", "expected the global Python 3.12 pin"
    PY
    for term in 'uv sync' 'uv run' 'Do not add `flake.nix`' '~/.local/share/worktrees/<repo>/<name>'; do
      grep -Fq -- "$term" "$instructions" || { echo "Missing global policy: $term" >&2; exit 1; }
    done
    touch "$out"
  ''
