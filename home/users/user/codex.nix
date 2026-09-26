# Codex CLI launcher shared by the desktop (home.nix) and gcp-agent (agent.nix)
# roles. Runs the newest upstream release through `npm exec` rather than
# nixpkgs, so it tracks upstream without a flake bump.
#
# A bare `@openai/codex@latest` is not enough: the npm package is a JS shim whose
# native binary ships as a per-platform optional dependency
# (`@openai/codex@<version>-<platform>`). Upstream has published a `latest`
# without one platform's binary (0.157.1 had no linux-x64); npm silently skips
# the missing optional dependency and the shim then dies with "Missing optional
# dependency @openai/codex-linux-x64". Upstream also maintains a per-platform
# dist-tag (`linux-x64`, `darwin-arm64`, ...) pointing at the newest release
# that has that binary, so fall back to it when `latest` lacks ours, and purge
# any cached npx install that was left without the binary.
{ pkgs, ... }:
let
  codex = pkgs.writeShellApplication {
    name = "codex";
    runtimeInputs = [
      pkgs.nodejs
      pkgs.jq
    ];
    text = ''
      pkg=@openai/codex
      platform=$(node -p 'process.platform + "-" + process.arch')
      version=latest

      # Offline or registry errors fall through to plain @latest.
      if tags=$(npm view "$pkg" dist-tags --json 2>/dev/null); then
        latest=$(jq -r '.latest // empty' <<<"$tags")
        platform_tag=$(jq -r --arg p "$platform" '.[$p] // empty' <<<"$tags")

        if [[ -n $latest && $platform_tag != "$latest-$platform" ]] &&
          ! npm view "$pkg@$latest-$platform" version >/dev/null 2>&1 &&
          [[ -n $platform_tag ]]; then
          version=''${platform_tag%-"$platform"}
          echo "codex: $latest has no $platform binary on npm; using $version" >&2
        fi
      fi

      # An npx install made while our binary was missing stays cached, and
      # npm exec keeps reusing it even after upstream publishes the binary.
      # Drop such installs so the next run reinstalls cleanly.
      for shim in "''${npm_config_cache:-$HOME/.npm}"/_npx/*/node_modules/@openai/codex; do
        if [[ -d $shim && ! -d $shim-$platform ]]; then
          rm -rf "''${shim%/node_modules/*}"
        fi
      done

      exec npm exec --yes --package "$pkg@$version" -- codex --dangerously-bypass-approvals-and-sandbox "$@"
    '';
  };
in
{
  home.packages = [ codex ];
}
