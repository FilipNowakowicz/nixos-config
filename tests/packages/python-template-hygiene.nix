# Hygiene test for the `python` flake template.
#
# `nix flake init -t ~/nix#python` copies templates/python/ verbatim into an
# unrelated project, so the template must stay generic: no host names, tailnet
# addresses, or secrets may leak in, and the advertised toolchain must remain
# wired up. This is a pure source grep — it needs no network and does not try to
# evaluate the template's separately-pinned nixpkgs.
{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  templateDir = ../../templates/python;
in
pkgs.runCommand "python-template-hygiene" { } ''
  files=(${templateDir}/flake.nix ${templateDir}/.envrc)

  fail() {
    echo "python-template-hygiene: $1" >&2
    exit 1
  }

  # 1. No personal assumptions: distinctive host names, tailnet CGNAT addresses
  #    (100.64.0.0/10), or secret-management references must not ride along into
  #    someone else's repo.
  forbidden='homeserver-gcp|gcp-builder|tailscale|tailnet|\bsops\b|\bsecrets?\b|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.'
  if grep -nEi "$forbidden" "''${files[@]}"; then
    fail "template references personal infrastructure (see matches above)"
  fi

  # 2. The advertised toolchain must stay present.
  for tool in python3 uv ruff basedpyright; do
    grep -qF "$tool" ${templateDir}/flake.nix \
      || fail "template no longer provides '$tool'"
  done

  touch $out
''
