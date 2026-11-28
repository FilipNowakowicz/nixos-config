# Substitute from the fleet's attic cache on homeserver-gcp (#631).
#
# The cache is an optimisation, never a dependency: it is tailnet-only and
# homeserver-gcp can be down, so every setting here keeps a dead cache cheap.
# - attic advertises priority 41, after cache.nixos.org's 40, so upstream
#   paths never touch it; only fleet-built paths are looked up there.
# - connect-timeout bounds each attempt to a few seconds (the default waits
#   for curl's own, much longer timeout). Nix then disables a failing
#   substituter for the rest of the session instead of retrying every path.
# - fallback builds locally when a substitute fails part-way, for example a
#   narinfo that answered and a NAR download that then broke.
{ hostRegistry, ... }:
let
  inherit ((import ../../../lib/binary-cache.nix)) fleetCache;
  inherit (hostRegistry.homeserver-gcp) tailnetFQDN;
in
{
  nix.settings = {
    substituters = [ "https://${tailnetFQDN}:${toString fleetCache.port}/${fleetCache.name}" ];
    trusted-public-keys = [ fleetCache.publicKey ];
    connect-timeout = 5;
    fallback = true;
  };
}
