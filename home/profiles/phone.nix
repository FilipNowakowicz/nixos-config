# The phone (Galaxy S24) over KDE Connect: its notifications here, a shared
# clipboard, files both ways, media control, ring-my-phone and its battery.
# Pairing runs over the tailnet only: main opens the ports on tailscale0
# (hosts/main/networking.nix, ports from lib/hosts.nix). On the phone, install
# KDE Connect and Tailscale, then add this machine by its tailnet IP.
_: {
  services.kdeconnect = {
    enable = true;
    # Its icon sits in the quiet shell's tray: pair, send a file, ring the phone.
    indicator = true;
  };
}
