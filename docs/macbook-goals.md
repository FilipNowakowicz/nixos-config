# MacBook Air Goals

Repurpose a 2017 MacBook Air 13-inch (A1466) as a home server node integrated
into the existing Tailscale mesh and observability stack.

## Hardware

| Component   | Detail                                                |
| :---------- | :---------------------------------------------------- |
| CPU         | Intel Core i5-5350U (Broadwell, x86_64)               |
| GPU         | Intel HD Graphics 6000 (modesetting, headless)        |
| WiFi        | Broadcom BCM4360 — needs firmware (see below)         |
| Storage     | Apple PCIe SSD — seen by Linux as `/dev/nvme0n1`      |
| Ethernet    | No built-in port — USB-to-ethernet adapter required   |
| Secure Boot | No T2 chip (pre-2018) — standard EFI boot, no lockout |

## Recommended Use

**Syncthing home node + Tailscale subnet router.**

- Always-on Syncthing peer on the LAN — files sync even when `main` is off,
  removes GCP as a single point of failure for data availability.
- Subnet router exposes home LAN devices on the tailnet without each needing
  Tailscale installed.
- Reports into the existing LGTM stack via `observability-client`.

Everything else considered and rejected:

- **Workstation:** weaker than `main` in every dimension; no compelling reason
  for a second dev machine at the same location.
- **VM host:** dual-core i5 + 8 GB RAM is too constrained for meaningful
  MicroVM workloads.
- **Mirror of homeserver-gcp services:** adds operational complexity (two
  instances of Vaultwarden, Grafana, etc.) without clear benefit.

## Prerequisites

Before starting:

- [ ] Check actual storage: Apple menu → About This Mac → Storage (128 GB or 256 GB).
- [ ] Arrange wired network for install — the minimal installer ISO has no
      BCM4360 firmware. A **USB-to-ethernet adapter** is the safest option;
      iPhone USB tethering may also work as temporary ethernet.
- [ ] Confirm a USB drive is available for the installer ISO.

## Implementation Plan

### 1. Host registry entry (`lib/hosts.nix`)

```nix
macbook-air = {
  system = "x86_64-linux";
  status = "active";
  homeManager.role = "server";
  tailnetFQDN = "macbook-air.<tailnet>.ts.net";  # fill in after first Tailscale auth
  tailscale = {
    tag = "server";
    acceptFrom.workstation = [ 22 ];
  };
  backup.class = "standard";
  deploy.sshUser = "user";
};
```

### 2. Disk layout (`hosts/macbook-air/disko.nix`)

Plain ext4 or Btrfs on `/dev/nvme0n1`. No impermanence needed for a server
unless explicitly wanted. Mirror the `homeserver-gcp` disko layout as a
starting point.

### 3. Host config (`hosts/macbook-air/default.nix`)

Minimal imports:

```nix
imports = [
  ./hardware-configuration.nix
  ./disko.nix
  ../../modules/nixos/profiles/base.nix
  ../../modules/nixos/profiles/machine-common.nix
  ../../modules/nixos/profiles/security.nix
  ../../modules/nixos/profiles/sops-base.nix
  ../../modules/nixos/profiles/user.nix
];
```

Host-specific config:

```nix
# WiFi — try redistributable firmware first; fall back to broadcom_sta if needed
hardware.enableRedistributableFirmware = true;
# boot.kernelModules = [ "wl" ];
# boot.extraModulePackages = [ config.boot.kernelPackages.broadcom_sta ];

services.thermald.enable = true;

# Syncthing currently comes from the Home Manager `server` role
# (`home/users/user/server.nix`); keep that unless a system-level service is
# intentionally introduced.

# Tailscale subnet router
services.tailscale.enable = true;
services.tailscale.useRoutingFeatures = "server";
```

### 4. Observability client

Enable `profiles.observability-client` to report into the existing Grafana/Loki
stack on `homeserver-gcp`. No new dashboards needed — the existing node
dashboard will pick it up automatically.

### 5. Invariant checks (`flake/checks.nix`)

Add a block alongside the existing `invariants-main` and
`invariants-homeserver-gcp` entries:

```nix
invariants-macbook-air = invariants.mkInvariantCheck "macbook-air" (
  commonSystemInvariants
  ++ homeserverAccessInvariants   # reuse: tailscale-only SSH, firewall on
  ++ registryAssertionsFor "macbook-air"
) allNixosConfigs.macbook-air.config;
```

### 6. Syncthing ownership model

There is no shared `lib/syncthing.nix` registry in the current tree. Before
adding `macbook-air`, decide whether Syncthing should continue to be managed
per host through the Home Manager `server` role or whether the repo now has
enough always-on peers to justify introducing a typed registry.

### 7. Install

```bash
# Boot USB installer (hold Option on startup for Apple boot picker)
# Plug in USB-ethernet adapter before booting

# From dev machine once installer is up:
nixos-anywhere --flake '.#macbook-air' root@<installer-ip>
```

After first boot:

```bash
# Authenticate Tailscale, then update tailnetFQDN in lib/hosts.nix
sudo tailscale up --advertise-routes=<home-cidr>

# Approve subnet routes in Tailscale admin console
```

### 8. Operations entry (`docs/operations.md`)

Add `macbook-air` to the deployment matrix and note the deploy-rs command once
confirmed working.

## Acceptance Criteria

- [ ] Host evaluates cleanly in `nix flake check`.
- [ ] Invariant checks pass.
- [ ] Syncthing syncs with both `main` and `homeserver-gcp`.
- [ ] Host appears in Grafana node dashboard.
- [ ] SSH accessible from `main` over Tailscale.
- [ ] Subnet routes approved and home LAN devices reachable on tailnet.
