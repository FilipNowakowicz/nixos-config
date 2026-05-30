## Anonymous Specialisation

`main` has a boot-selectable `anonymous` specialisation. Select the
`nixos-anonymous-...` entry from the bootloader; do not attempt to switch at
runtime. It is an **amnesic, hardened launchpad**, not an anonymous OS:

- `/home/user` is a **tmpfs** — every boot is a clean slate (no logins, cookies,
  history, or scan artifacts). Home Manager repopulates declarative dotfiles
  from the store on boot; session _data_ is gone on reboot. Copy off-host
  anything you want to keep.
- Fresh transient **machine-id** each boot; the real `@home` is shadowed (not
  wiped) while this spec runs.
- Disables Tailscale, SSH, Bluetooth, observability, and backups; enables
  AppArmor and kernel hardening; **Mullvad** auto-connects + explicit-connects
  with lockdown always on; starts a **Tor** SOCKS5 proxy on `127.0.0.1:9050`
  with `proxychains` wired to it (`strict_chain`, `proxy_dns`).

Routing model: **active scans exit via Mullvad** (origin-hiding, full protocol
support); **Tor (`proxychains`/`torsocks`) is TCP-`connect()` only** — for
OSINT/recon, never raw/SYN/UDP scans; **anonymous browsing belongs in
Whonix-Workstation** (Tor Browser), the only topology-enforced anonymous
surface.

Quick commands inside the anonymous boot:

```bash
# Check Mullvad is connected and lockdown is active
mullvad status
mullvad lockdown-mode get

# OSINT/recon TCP tool through Tor (NOT -sS/-sU/masscan — those bypass SOCKS)
proxychains nmap -sT -Pn <target>

# Active scan: exit via Mullvad (no proxychains), origin hidden by the tunnel
nmap -sS -Pn <target>

# Start Whonix (Gateway first, then Workstation), browse via its Tor Browser
sudo virsh start Whonix-Gateway
sudo virsh start Whonix-Workstation
```

Full details: `docs/security.md` § Anonymous Specialisation.
