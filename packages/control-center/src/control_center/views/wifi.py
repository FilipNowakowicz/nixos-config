"""Wi-Fi detail view: hero card, stat strip, network list."""

from gi.repository import GLib, Gtk

from ..actions import (
    act_connect_wifi,
    act_open_hidden_wifi,
    act_open_network_settings,
    act_set_wifi_radio,
    act_wifi_rescan,
)
from ..constants import G


class WifiViewMixin:
    def _build_wifi_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        sw = self._switch()
        view.append(self._detail_header("Wi-Fi", right_widget=sw))

        def _on_wifi_toggle(_b):
            current = self.effective(
                "wifi.enabled", self.state["wifi"]["enabled"],
            )
            target = not current
            self._pending_set("wifi.enabled", target, ttl_s=4)
            self._set_class(sw, "on", target)
            act_set_wifi_radio(target)
        sw.connect("clicked", _on_wifi_toggle)

        hero = self._hero_card_ref()
        view.append(hero.widget)
        strip = Gtk.Grid(column_homogeneous=True, column_spacing=6)
        strip.add_css_class("vpn-stat")
        view.append(strip)

        section = self._section_label("Available Networks", action="Rescan")
        section_btn = section.get_last_child()
        view.append(section)
        lst = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(lst)
        settings_btn = self._ghost_btn("Open Network Settings")
        view.append(settings_btn)

        def _rescan_done():
            section_btn.set_label("Rescan")
            self._tick_slow()
            return False

        def _on_rescan(_b):
            section_btn.set_label("Scanning...")
            act_wifi_rescan()
            GLib.timeout_add(1800, _rescan_done)
        section_btn.connect("clicked", _on_rescan)

        def _on_settings(_b):
            self._hide_window()
            act_open_network_settings()
        settings_btn.connect("clicked", _on_settings)

        def refresh(s):
            w = s["wifi"]
            enabled = self.effective("wifi.enabled", w["enabled"])
            self._set_class(sw, "on", enabled)

            hero.icon.set_label(self._wifi_glyph(w["signal_pct"]) if w["enabled"] else G["wifi"])
            if w["enabled"] and w["connected"] and w["ssid"]:
                hero.title.set_label(self._short(w["ssid"], 28))
                ip = w["ip"] or "—"
                gw = f" · gw {w['gateway']}" if w["gateway"] else ""
                sec = w["security"] or "—"
                hero.sub.set_label(self._short(f"{sec} · {ip}{gw}", 56))
                hero.big.set_label(f"{w['signal_pct']}")
                hero.small.set_label("signal")
            elif w["enabled"]:
                hero.title.set_label("Not connected")
                hero.sub.set_label("Pick a network below")
                hero.big.set_label("—")
                hero.small.set_label("")
            else:
                hero.title.set_label("Wi-Fi off")
                hero.sub.set_label("Enable to scan")
                hero.big.set_label("—")
                hero.small.set_label("")

            self._fill_stat_grid(strip, [
                (w["band"] or "—", "band"),
                (f"{w['signal_pct']}%" if w["enabled"] else "—", "signal"),
                (f"{w['freq_mhz']}" if w["freq_mhz"] else "—", "MHz"),
            ])

            self._clear(lst)
            if not enabled:
                lst.append(self._drawer_item(
                    G["wifi"], "Wi-Fi disabled",
                    "Toggle the switch above to enable", "—", subtle=True,
                ))
            else:
                shown = 0
                for net in w["networks"]:
                    if net["active"]:
                        continue  # active is in hero
                    if shown >= 6:
                        break
                    parts = [s for s in (net["security"], net["band"]) if s]
                    subtitle = " · ".join(parts) or "—"
                    subtle = net["security"] in ("", "Open", "--")
                    row = self._drawer_item(
                        self._wifi_glyph(net["signal"]),
                        self._short(net["ssid"], 24),
                        subtitle, f"{net['signal']}%",
                        subtle=subtle,
                    )

                    def _on_connect(_b, ssid=net["ssid"]):
                        self._pending_set("wifi.ssid", ssid, ttl_s=10)
                        act_connect_wifi(ssid)
                    row.connect("clicked", _on_connect)
                    lst.append(row)
                    shown += 1
                if shown == 0:
                    lst.append(self._drawer_item(
                        G["wifi"], "No networks", "Try Rescan", "—",
                        subtle=True,
                    ))
                hidden = self._drawer_item(
                    G["plus"], "Hidden Network", "Join by SSID", "›",
                    subtle=True,
                )
                hidden.connect("clicked", lambda _b: (
                    self._hide_window(), act_open_hidden_wifi(),
                ))
                lst.append(hidden)

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
