_: {
  # Broad passwordless sudo for disposable/dev-only machines. Do not import this
  # profile on multi-user or untrusted-shell hosts.
  security.sudo.wheelNeedsPassword = false;

  services.openssh.openFirewall = true;

  profiles.nix.extraTrustedUsers = [ "user" ];
}
