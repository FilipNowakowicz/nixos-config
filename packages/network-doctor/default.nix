{ pkgs, hostRegistry, ... }:
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "network-doctor";
      runtimeInputs = with pkgs; [
        coreutils
        iproute2
        jq
        bind.host
        curl
        glibc.bin
      ];
      runtimeEnv = {
        ADGUARD_ADDRESS = hostRegistry.homeserver-gcp.tailscale.ip4;
        MAGICDNS_NAME = hostRegistry.homeserver-gcp.tailnetFQDN;
      };
      text = builtins.readFile ./network-doctor.sh;
    })
  ];
}
