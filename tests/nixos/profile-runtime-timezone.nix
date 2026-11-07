# The runtime timezone survives a rolled-back root: a zone set through
# timedatectl is saved, and restored when /etc/localtime is gone at boot.
{ nixpkgs, system }:
let
  pkgs = import nixpkgs { inherit system; };
in
(import "${nixpkgs}/nixos/lib/testing-python.nix" {
  inherit system pkgs;
}).runTest
  {
    name = "profile-runtime-timezone";

    nodes.machine = {
      imports = [ ../../modules/nixos/profiles/runtime-timezone.nix ];
      profiles.runtimeTimezone = {
        enable = true;
        default = "Europe/London";
      };
    };

    testScript = ''
      def zone():
          return machine.succeed("readlink /etc/localtime").strip().split("zoneinfo/")[-1]

      def restore():
          # What a rolled-back root looks like at boot.
          machine.succeed("rm -f /etc/localtime && systemctl restart restore-timezone.service")

      machine.wait_for_unit("multi-user.target")

      with subtest("the default applies before any choice"):
          assert zone() == "Europe/London", zone()

      with subtest("a zone set at runtime is saved"):
          machine.succeed("timedatectl set-timezone Europe/Warsaw")
          machine.wait_until_succeeds("grep -qx Europe/Warsaw /var/lib/runtime-timezone/zone")

      with subtest("and restored when /etc/localtime is gone"):
          restore()
          assert zone() == "Europe/Warsaw", zone()
          assert "Europe/Warsaw" in machine.succeed("timedatectl show -p Timezone")

      with subtest("an unknown saved zone falls back to the default"):
          machine.succeed("echo Atlantis/Nowhere > /var/lib/runtime-timezone/zone")
          restore()
          assert zone() == "Europe/London", zone()
    '';
  }
