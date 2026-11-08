# Fleet-wide binary-cache substituters and trusted public keys.
#
# Single source of truth for binary-cache identity shared across hosts. A
# signing-key rotation should update the relevant value here, then follow the
# "Binary Cache Trust" rotation procedure in docs/security.md for the other
# files that must stay in sync (e.g. .github/actions/setup-nix/action.yml,
# checked against hosts/main/default.nix by scripts/check-cache-config.sh).
{
  # R2-hosted CI cache, trusted by `main`.
  r2 = {
    substituter = "https://pub-706604c9179043ac98604d6de4c65c2c.r2.dev";
    publicKey = "nix-cache-1:eEcFiWPHQpJmlcnNeGoPg6xxOp3itNZiWwFaE+NebIk=";
  };

  # cache.nixos.org and the main.local cache served by `main`, trusted by
  # homeserver-gcp and gcp-builder.
  cacheNixosOrgPublicKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
  mainLocalPublicKey = "main.local:fSo1pk+WU1RU7vpv+GTbzldKn4MMtBS46vQasXJ2oeQ=";
}
