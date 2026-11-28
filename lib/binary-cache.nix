# Fleet-wide binary-cache trusted public keys.
{
  # cache.nixos.org and the main.local cache served by `main`, trusted by
  # homeserver-gcp and gcp-builder.
  cacheNixosOrgPublicKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
  mainLocalPublicKey = "main.local:fSo1pk+WU1RU7vpv+GTbzldKn4MMtBS46vQasXJ2oeQ=";

  # The attic cache on homeserver-gcp (hosts/homeserver-gcp/attic.nix), fed by
  # gcp-builder and substituted by main, homeserver-gcp and gcp-builder
  # (modules/nixos/profiles/fleet-cache.nix). The secret half is
  # `attic_signing_key` in hosts/homeserver-gcp/secrets/attic.yaml; atticd-init
  # refuses to run if the two disagree. `port` is the tailnet-only nginx
  # listener, also granted in lib/hosts.nix.
  fleetCache = {
    name = "fleet";
    port = 8443;
    publicKey = "fleet-cache-1:JWPb8f+sHyIyWwnqwHd86ITtOTWmrsBStKeDJHZAQyU=";
  };
}
