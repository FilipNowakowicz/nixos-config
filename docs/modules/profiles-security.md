# `nixosModules.profiles-security`

An opinionated host security baseline with no options of its own. Importing it
turns the settings on; override individual values in your own configuration
with `lib.mkForce` where you need to.

```nix
# flake.nix
{
  inputs.nixos-fleet.url = "github:FilipNowakowicz/nixos-config";

  outputs =
    { nixpkgs, nixos-fleet, ... }:
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-fleet.nixosModules.profiles-security
          ./configuration.nix
        ];
      };
    };
}
```

## What it sets

- **Firewall:** `networking.firewall.enable` and nftables.
- **SSH:** OpenSSH stays off unless you enable it (`mkDefault false`). When on,
  root login and password/keyboard-interactive authentication are disabled.
- **fail2ban:** enabled with three retries, a 30-minute ban and incremental bans
  up to 24 hours across jails. An assertion fails evaluation if SSH is enabled
  and that fail2ban configuration has been weakened.
- **Warnings:** evaluation warns when SSH uses `openFirewall = true`, or when a
  Tailscale host leaves TCP 22 or 443 open on every interface.
- **Kernel sysctls:** restricted BPF, kernel pointers, dmesg and ptrace;
  kexec disabled; ICMP broadcast echo, redirects and source routing ignored.
- **Coredumps:** kept in the journal, compressed, capped at 512 MiB per process
  and 1 GiB in total.

## Tests

- `profile-security` (VM test, `scripts/validate.sh profile-tests`) boots a host
  with the module and checks the sysctls, the effective `sshd` settings, and
  that repeated failed SSH logins get the attacker banned.
- `public-modules-standalone` evaluates the export on its own with no other
  module from this repository.
