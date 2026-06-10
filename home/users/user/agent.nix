# Minimal Home Manager role for `gcp-agent`: a headless box that runs Claude
# Code sessions (issue-loop orchestration), not an interactive workstation.
#
# It deliberately does NOT pull in the desktop-only userSecrets module
# (home/users/user/secrets.nix, imported by home.nix). That machinery decrypts
# the `&user`-shared auth files with the personal age key
# (~/.config/sops/age/keys.txt); placing that key on a disposable, autonomously
# running box would give it blast-radius over every `&user` secret on every
# host. Instead this host's `claude` credentials and its scoped GitHub PAT are
# delivered as *host* sops secrets (decrypted by the host SSH key) — see
# hosts/gcp-agent/default.nix. Git identity is therefore set directly here
# rather than rendered from the `&user` sops template.
{ pkgs, ... }:
let
  codexLatest = pkgs.writeShellApplication {
    name = "codex";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npm exec --yes --package @openai/codex@latest -- codex --dangerously-bypass-approvals-and-sandbox "$@"
    '';
  };

  claudeLatest = pkgs.writeShellApplication {
    name = "claude";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npx -y @anthropic-ai/claude-code@latest --dangerously-skip-permissions "$@"
    '';
  };
in
{
  imports = [ ./common.nix ];

  programs.git.settings = {
    # The desktop-only userSecrets module is not imported here, so the sops
    # git-identity template is not rendered; set the (non-secret) identity
    # directly so orchestration commits are attributed correctly. Mirrors the
    # table note in docs/security.md that git_user_name/_email are static
    # identity, not rotating credentials.
    user.name = "Filip Nowakowicz";
    user.email = "filip.nowakowicz@gmail.com";

    # The scoped GitHub PAT is delivered to ~/.config/gh/hosts.yml (host sops
    # secret). Route git's HTTPS credentials through gh so `git push` and
    # `gh` API calls share the one token — the declarative equivalent of
    # `gh auth setup-git`.
    credential."https://github.com".helper = "${pkgs.gh}/bin/gh auth git-credential";
  };

  home.packages = [
    pkgs.gh
    pkgs.nodejs
    codexLatest
    claudeLatest
  ];
}
