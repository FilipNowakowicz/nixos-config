{
  pkgs,
  pre-commit-hooks,
  system,
  treefmtEval,
}:
let
  treefmtWrapper = pkgs.writeShellScript "treefmt-wrapper" ''
    set -euo pipefail
    exec ${treefmtEval.config.build.wrapper}/bin/treefmt "$@"
  '';

  statixStaged = pkgs.writeShellScript "statix-staged" ''
    set -euo pipefail

    has_failed=0
    for path in "$@"; do
      ${pkgs.statix}/bin/statix check --format errfmt "$path" || has_failed=1
    done

    exit "$has_failed"
  '';

  # Single source of truth for the plaintext-secret regex, shared with
  # scripts/scan-plaintext-secrets.sh. Editing the pattern file updates both the
  # pre-commit hook and the CI scan. The trailing newline from the file is
  # stripped so the embedded pattern matches the script's `$(<file)` read.
  plaintextSecretPattern = pkgs.lib.removeSuffix "\n" (
    builtins.readFile ./scripts/lib/plaintext-secret-pattern.txt
  );

  noPlaintextSecrets = pkgs.writeShellScript "no-plaintext-secrets" ''
    set -euo pipefail

    allowlist_file=".plaintext-secrets-allowlist"
    has_failed=0
    pattern=${pkgs.lib.escapeShellArg plaintextSecretPattern}

    is_valid_staged_secrets_path() {
      local path="$1"
      case "$path" in
        *.enc|*.age)
          return 0
          ;;
        *.yaml|*.yml)
          git show ":$path" 2>/dev/null | grep -Eq '^[[:space:]]*sops:'
          return
          ;;
        *)
          return 1
          ;;
      esac
    }

    is_allowlisted() {
      local path="$1"
      while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$path" == $line ]]; then
          return 0
        fi
      done < <(git show ":$allowlist_file" 2>/dev/null)
      return 1
    }

    for path in "$@"; do
      if ! git cat-file -e ":$path" 2>/dev/null; then
        continue
      fi

      case "$path" in
        hosts/*/secrets/*)
          if is_valid_staged_secrets_path "$path"; then
            continue
          fi
          echo "Invalid staged file under hosts/*/secrets/*: $path" >&2
          echo "Allowed file types are .enc, .age, and SOPS-managed .yaml/.yml." >&2
          has_failed=1
          continue
          ;;
      esac

      case "$path" in
        *.enc|*.age|.sops.yaml|flake.lock|result|result-*)
          continue
          ;;
      esac

      if is_allowlisted "$path"; then
        continue
      fi

      if git show ":$path" | grep -Einq "$pattern"; then
        echo "Potential plaintext secret in staged file: $path" >&2
        echo "Stage an entry in .plaintext-secrets-allowlist and re-run the commit if this is intentional." >&2
        has_failed=1
      fi
    done

    exit "$has_failed"
  '';
in
pre-commit-hooks.lib.${system}.run {
  src = ./.;

  hooks = {
    treefmt = {
      enable = true;
      entry = "${treefmtWrapper}";
      language = "system";
      pass_filenames = false;
      files = "";
    };
    deadnix.enable = true;
    shellcheck.enable = true;

    statix-staged = {
      enable = true;
      name = "statix";
      entry = "${statixStaged}";
      language = "system";
      pass_filenames = true;
      files = "\\.nix$";
    };

    no-plaintext-secrets = {
      enable = true;
      name = "no-plaintext-secrets";
      entry = "${noPlaintextSecrets}";
      language = "system";
      pass_filenames = true;
      types = [ "text" ];
    };

    secrets-directory-enforcement = {
      enable = true;
      name = "secrets-directory-enforcement";
      entry = "${pkgs.bash}/bin/bash ${./scripts/check-secrets-directory.sh} --staged";
      language = "system";
      pass_filenames = false;
      files = "";
    };
  };
}
