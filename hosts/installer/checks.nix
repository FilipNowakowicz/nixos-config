# The installer ISO is not a registry host but exposes SSH on TCP/22 to
# whatever network it boots on: it must stay key-only. flake/checks.nix runs
# `invariants` as `invariants-installer`.
{ invariants, ... }:
let
  inherit (invariants) mkResult;
in
{
  invariants = [
    {
      name = "installer SSH is key-only";
      check =
        cfg:
        let
          s = cfg.services.openssh.settings;
        in
        mkResult (
          s.PermitRootLogin == "prohibit-password"
          && s.PasswordAuthentication == false
          && s.KbdInteractiveAuthentication == false
        ) "installer sshd must allow only key-based root login";
    }
  ];
}
