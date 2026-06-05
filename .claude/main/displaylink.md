# DisplayLink External Monitor (USB dock)

`main` drives DisplayLink docks via `modules/nixos/hardware/displaylink.nix`.
DisplayLink is **not** a normal DP/HDMI output — the dock has no real DRM
connector. The unfree `DisplayLinkManager` daemon scrapes frames from the
`evdi` virtual GPU and ships them over USB. Three host quirks gate it working:
the unfree-blob prefetch, USBGuard, and Hyprland's GPU pinning.

> Prefer a real output if you can: a USB-C port with **DP-Alt-Mode**, or a dock's
> native DP/HDMI, needs _none_ of the below — see `hosts/main/CLAUDE.md` →
> external monitor notes. Use DisplayLink only when the dock is DL-protocol.

---

## 1. One-time: prefetch the unfree driver blob (MANDATORY)

`pkgs.displaylink` is a `requireFile` — Nix cannot fetch it (Synaptics
redistribution terms). Until the blob is in the store, **`nh os switch` /
`rebuild` for `main` will fail to build.** This is by design; CI is unaffected
because `main-ci` sets `profiles.ci = true`, which disables the driver.

Current pin (from nixpkgs): **DisplayLink 6.2.0-30**, expected file
`displaylink-620.zip`, `sha256-JQO7eEz4pdoPkhcn9tIuy5R4KyfsCniuw6eXw/rLaYE=`.

1. Download "DisplayLink USB Graphics Software for Ubuntu 6.2" (a `.zip`) from
   <https://www.synaptics.com/products/displaylink-graphics/downloads> —
   requires accepting their EULA in a browser, so it can't be automated.
2. Add it to the store under the name Nix expects:
   ```bash
   nix-store --add-fixed sha256 ~/Downloads/DisplayLink_Ubuntu_6.2.zip
   # or let Nix tell you the exact name/hash it wants:
   nix-build '<nixpkgs>' -A displaylink   # prints the precise add-fixed command on failure
   ```
   The store name must resolve to `displaylink-620.zip` with the hash above. If
   the bump landed a newer version, run the `nix-build` form and copy the
   command it prints verbatim.
3. Re-run `rebuild`. The blob persists in `/nix/store`; this is per-version, so
   redo it whenever a `flake.lock` bump changes the DisplayLink version.

---

## 2. One-time: allow the dock through USBGuard

`hosts/main/default.nix` default-**rejects** all USB. The dock (and usually its
built-in hub) will be blocked and won't even enumerate until whitelisted.

1. Plug the dock in. Find what was blocked:
   ```bash
   journalctl -b -u usbguard | rg -i block
   sudo usbguard list-devices --blocked
   ```
2. Note the `id <VID:PID>`, `serial`, and interface set for the DisplayLink
   device (Synaptics/DisplayLink VID is commonly `17e9`) **and** any companion
   hub it presents.
3. Add `allow` rules to `services.usbguard.rules` in `hosts/main/default.nix`,
   matching the existing entries' style (pin `id` + `serial` where possible).
   Keep the trailing `reject`. Then `rebuild`.

This file intentionally does **not** ship a placeholder rule — an unkeyed allow
in that security-sensitive block would be worse than none.

---

## 3. Verify

Connect the dock **before** logging into Hyprland (DisplayLink hotplug into a
running aquamarine session is unreliable — see below).

```bash
systemctl status dlm                 # DisplayLinkManager should be active
ls -l /dev/dri/displaylink           # evdi symlink present once a sink is created
hyprctl monitors all                 # the DisplayLink output should be listed
```

Once it appears, give it a deterministic place in `home/files/hypr/hyprland.conf`
(replace the catch-all `monitor = ,preferred,auto,1`), e.g.:

```
monitor = eDP-1,    preferred, 0x0,    1
monitor = DVI-I-1,  preferred, 1920x0, 1   # name as shown by `hyprctl monitors`
```

DisplayLink outputs typically enumerate as `DVI-I-N` / `DP-N`. Test live first
with `hyprctl keyword monitor "<name>,preferred,1920x0,1"` before committing.

---

## Gotchas

- **Hyprland won't start with no dock attached?** `AQ_DRM_DEVICES` lists
  `/dev/dri/displaylink`, which is absent when nothing is connected. aquamarine
  normally skips a missing secondary device, but if a login ever fails on a
  dock-less boot, revert `AQ_DRM_DEVICES` in `displaylink.nix` to the intel-only
  value (`lib.mkForce "/dev/dri/intel-igpu"`) and only widen it on demand.
- **Greeter → session evdi corruption.** Known upstream issue: evdi can keep
  stale state across the greetd→Hyprland compositor handoff, giving a garbled
  DisplayLink image. Workaround: `sudo modprobe -r evdi && sudo modprobe evdi`
  with the session restarted, or reconnect the dock after login.
- **Performance.** DisplayLink is CPU-compressed USB framebuffer streaming — fine
  for static/office work, poor for video/gaming. The dGPU is unrelated here;
  rendering stays on the Intel iGPU.
- **Thunderbolt docks.** If the dock is TB (not plain USB), `iommu=force` +
  Thunderbolt authorization apply on top of USBGuard. Most DisplayLink docks are
  USB 3.x, not TB.
- **CI is intentionally blind to this.** The driver is `!profiles.ci`-gated, so
  `merge-gate` builds `main-ci` without the blob. Only the real `main` closure
  pulls DisplayLink, and only after step 1.
