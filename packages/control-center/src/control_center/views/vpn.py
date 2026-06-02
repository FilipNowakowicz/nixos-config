"""VPN detail view: Tailscale + Mullvad sections, exit node and location pickers."""

from gi.repository import Gtk

from ..actions import (
    act_mullvad_connect,
    act_mullvad_disconnect,
    act_mullvad_set_location,
    act_open_vpn_tools,
    act_tailscale_down,
    act_tailscale_exit_node,
    act_tailscale_up,
)
from ..constants import G


class VpnViewMixin:
    def _build_vpn_view(self):
        caps = self.state.get("caps", {})
        ts_available = caps.get("tailscale", True)
        mv_available = caps.get("mullvad", True)
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        meta = self._label("", "panel-meta", xalign=1)
        view.append(self._detail_header("VPN", right_widget=meta))

        # Tailscale section
        ts_section = self._box(
            Gtk.Orientation.VERTICAL, spacing=10, css="vpn-section",
        )
        head = self._box(
            Gtk.Orientation.HORIZONTAL, spacing=12, css="vpn-head",
        )
        ic = self._label(G["shield"], "vpn-icon", xalign=0.5)
        self._center_icon(ic)
        ic.set_width_chars(3)
        ic.set_halign(Gtk.Align.CENTER)
        ic.set_valign(Gtk.Align.CENTER)
        head.append(ic)
        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        copy.append(self._label("Tailscale", "vpn-name"))
        ts_sub = self._label("", "vpn-sub")
        copy.append(ts_sub)
        head.append(copy)
        ts_sw = self._switch()
        ts_sw.set_sensitive(ts_available)
        head.append(ts_sw)
        ts_section.append(head)

        def _on_ts_toggle(_b):
            target = not self.effective(
                "tailscale.enabled", self.state["tailscale"]["enabled"],
            )
            self._pending_set("tailscale.enabled", target, ttl_s=10)
            self._set_class(ts_sw, "on", target)
            self._set_class(ts_section, "off", not target)
            if target:
                act_tailscale_up()
            else:
                act_tailscale_down()
        ts_sw.connect("clicked", _on_ts_toggle)

        ts_strip = Gtk.Grid(column_homogeneous=True, column_spacing=6)
        ts_strip.add_css_class("vpn-stat")
        ts_section.append(ts_strip)
        ts_exit_btn = Gtk.Button()
        ts_exit_btn.set_sensitive(ts_available)
        ts_exit_btn.add_css_class("drawer-select")
        exit_inner = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
        ts_exit_name = self._label("None")
        exit_inner.append(ts_exit_name)
        exit_inner.append(self._label(G["chevron_right"]))
        ts_exit_btn.set_child(exit_inner)

        ts_exit_popover = Gtk.Popover()
        ts_exit_popover.set_parent(ts_exit_btn)
        ts_exit_popover.set_position(Gtk.PositionType.BOTTOM)
        ts_exit_box = self._box(
            Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list",
        )
        ts_exit_popover.set_child(ts_exit_box)

        def _on_exit_btn_click(_b):
            self._clear(ts_exit_box)
            none_btn = self._drawer_item(
                G["globe"], "None", "Direct, no exit node", "›",
                subtle=False,
            )

            def _pick_none(_b):
                self._pending_set("tailscale.exit_node", "None", ttl_s=8)
                ts_exit_name.set_label("None")
                act_tailscale_exit_node("")
                ts_exit_popover.popdown()
            none_btn.connect("clicked", _pick_none)
            ts_exit_box.append(none_btn)
            for p in self.state["tailscale"]["peers"]:
                if p["this"] or not p["online"]:
                    continue
                row = self._drawer_item(
                    G["server"], self._short(p["name"], 22),
                    p["ip"] or "—", "›",
                )

                def _pick(_b, name=p["name"]):
                    self._pending_set("tailscale.exit_node", name, ttl_s=10)
                    ts_exit_name.set_label(name)
                    act_tailscale_exit_node(name)
                    ts_exit_popover.popdown()
                row.connect("clicked", _pick)
                ts_exit_box.append(row)
            ts_exit_popover.popup()
        ts_exit_btn.connect("clicked", _on_exit_btn_click)

        ts_section.append(self._drawer_row(
            G["globe"], "Exit Node",
            "Route all traffic through a tailnet peer",
            ts_exit_btn,
        ))
        ts_peer_section = self._section_label("Tailnet")
        ts_section.append(ts_peer_section)
        ts_peer_count_lbl = ts_peer_section.get_first_child()
        ts_list = self._box(
            Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list",
        )
        ts_section.append(ts_list)
        view.append(ts_section)

        # Mullvad section
        mv_section = self._box(
            Gtk.Orientation.VERTICAL, spacing=10,
            css=["vpn-section", "off"],
        )
        head = self._box(
            Gtk.Orientation.HORIZONTAL, spacing=12, css="vpn-head",
        )
        ic = self._label(G["key"], "vpn-icon", xalign=0.5)
        self._center_icon(ic)
        ic.set_width_chars(3)
        ic.set_halign(Gtk.Align.CENTER)
        ic.set_valign(Gtk.Align.CENTER)
        head.append(ic)
        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        copy.append(self._label("Mullvad", "vpn-name"))
        mv_sub = self._label("", "vpn-sub")
        copy.append(mv_sub)
        head.append(copy)
        mv_sw = self._switch()
        mv_sw.set_sensitive(mv_available)
        head.append(mv_sw)
        mv_section.append(head)

        def _on_mv_toggle(_b):
            target = not self.effective(
                "mullvad.connected", self.state["mullvad"]["connected"],
            )
            self._pending_set("mullvad.connected", target, ttl_s=10)
            self._set_class(mv_sw, "on", target)
            self._set_class(mv_section, "off", not target)
            if target:
                act_mullvad_connect()
            else:
                act_mullvad_disconnect()
        mv_sw.connect("clicked", _on_mv_toggle)

        # Inline build of the location row so we can update its labels.
        mv_loc_row = self._box(
            Gtk.Orientation.HORIZONTAL, spacing=10, css="drawer-row",
        )
        mv_loc_icon = self._label("—", "di-icon", xalign=0.5)
        self._center_icon(mv_loc_icon)
        mv_loc_icon.set_width_chars(2)
        mv_loc_icon.set_valign(Gtk.Align.CENTER)
        mv_loc_row.append(mv_loc_icon)
        loc_copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        loc_copy.set_hexpand(True)
        mv_loc_name = self._label("—", "di-name")
        mv_loc_sub = self._label("", "di-sub")
        loc_copy.append(mv_loc_name)
        loc_copy.append(mv_loc_sub)
        mv_loc_row.append(loc_copy)
        mv_change_btn = self._drawer_select("Change")
        mv_change_btn.set_sensitive(mv_available)
        mv_loc_row.append(mv_change_btn)
        mv_section.append(mv_loc_row)

        # Mullvad location picker — curated short list. Full server list
        # via `mullvad relay list` is huge (1000+ rows); these covers most
        # daily use.
        mv_locs = [
            ("SE", "Sweden", "Stockholm", "se sto"),
            ("DE", "Germany", "Frankfurt", "de fra"),
            ("CH", "Switzerland", "Zürich", "ch zrh"),
            ("NL", "Netherlands", "Amsterdam", "nl ams"),
            ("GB", "United Kingdom", "London", "gb lon"),
            ("US", "USA", "New York", "us nyc"),
            ("JP", "Japan", "Tokyo", "jp tyo"),
        ]
        mv_popover = Gtk.Popover()
        mv_popover.set_parent(mv_change_btn)
        mv_popover.set_position(Gtk.PositionType.BOTTOM)
        mv_picker_box = self._box(
            Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list",
        )
        for code, country, city, loc in mv_locs:
            r = self._drawer_item(
                code, self._short(country, 22), city, "›",
            )

            def _pick_loc(_b, lc=loc, lbl=f"{country}, {city}"):
                self._pending_set("mullvad.preferred", lbl, ttl_s=8)
                act_mullvad_set_location(lc)
                mv_popover.popdown()
            r.connect("clicked", _pick_loc)
            mv_picker_box.append(r)
        mv_popover.set_child(mv_picker_box)
        mv_change_btn.connect("clicked", lambda _b: mv_popover.popup())

        view.append(mv_section)
        vpn_tools_btn = self._ghost_btn("Open VPN Tools")
        vpn_tools_btn.connect("clicked", lambda _b: (
            self._hide_window(), act_open_vpn_tools(),
        ))
        view.append(vpn_tools_btn)

        def refresh(s):
            ts = s["tailscale"]; mv = s["mullvad"]
            ts_enabled = ts_available and self.effective(
                "tailscale.enabled", ts["enabled"],
            )
            mv_connected = mv_available and self.effective(
                "mullvad.connected", mv["connected"],
            )
            total = (1 if ts_available else 0) + (1 if mv_available else 0)
            active = (1 if ts_enabled else 0) + (1 if mv_connected else 0)
            meta.set_label(f"{active} of {total} active")

            if not ts_available:
                self._set_class(ts_sw, "on", False)
                self._set_class(ts_section, "off", True)
                ts_sub.set_label("Not installed · tailscale not on PATH")
                self._fill_stat_grid(ts_strip, [
                    ("—", "peers"), ("—", "online"), ("—", "os"),
                ])
                ts_exit_name.set_label("None")
                ts_peer_count_lbl.set_label("Tailnet")
                self._clear(ts_list)
                ts_list.append(self._drawer_item(
                    G["server"], "Tailscale not installed",
                    "Install tailscale to manage your tailnet", "—",
                    subtle=True,
                ))
            else:
                self._refresh_tailscale_section(
                    ts, ts_enabled, ts_sw, ts_section, ts_sub, ts_strip,
                    ts_exit_name, ts_peer_count_lbl, ts_list,
                )

            self._refresh_mullvad_section(
                mv, mv_available, mv_connected, mv_sw, mv_section, mv_sub,
                mv_loc_icon, mv_loc_name, mv_loc_sub,
            )

        self._refreshers.append(refresh)
        refresh(self.state)
        return view

    def _refresh_tailscale_section(
        self, ts, ts_enabled, ts_sw, ts_section, ts_sub, ts_strip,
        ts_exit_name, ts_peer_count_lbl, ts_list,
    ):
        self._set_class(ts_sw, "on", ts_enabled)
        self._set_class(ts_section, "off", not ts_enabled)

        name = ts["name"] or "—"
        ip = ts["ip"] or "—"
        ts_sub.set_label(self._short(
            f"{name} · {ip} · WireGuard mesh"
            if ts_enabled else "Not connected", 56,
        ))

        peer_count = ts["peer_count"]
        online = sum(1 for p in ts["peers"] if p.get("online"))
        self._fill_stat_grid(ts_strip, [
            (str(peer_count), "peers"),
            (str(online), "online"),
            (ts["os"] or "—", "os"),
        ])
        ts_exit_name.set_label(self.effective(
            "tailscale.exit_node", ts["exit_node"] or "None",
        ))

        ts_peer_count_lbl.set_label(
            f"Tailnet · {peer_count} peer{'s' if peer_count != 1 else ''}"
        )
        self._clear(ts_list)
        if not ts["peers"]:
            ts_list.append(self._drawer_item(
                G["server"], "No peers",
                "Tailscale not running or empty tailnet", "—",
                subtle=True,
            ))
        else:
            for p in ts["peers"]:
                if p["os"] == "linux" and "server" in (p["name"] or ""):
                    glyph = G["server"]
                elif p["os"] in ("android", "iOS", "ios"):
                    glyph = G["phone"]
                elif p["os"] == "linux":
                    glyph = G["laptop"]
                else:
                    glyph = G["laptop"]
                if p["this"]:
                    right = "This"; status = "this"
                elif p["online"]:
                    right = "Online"; status = "online"
                else:
                    right = "Offline"; status = None
                sub = (f"{p['ip']} · this device"
                       if p["this"] else (p["ip"] or "—"))
                ts_list.append(self._drawer_item(
                    glyph, self._short(p["name"] or "?", 22),
                    sub, right, active=p["online"], status=status,
                ))

    def _refresh_mullvad_section(
        self, mv, mv_available, mv_connected, mv_sw, mv_section, mv_sub,
        mv_loc_icon, mv_loc_name, mv_loc_sub,
    ):
        if not mv_available:
            self._set_class(mv_sw, "on", False)
            self._set_class(mv_section, "off", True)
            mv_sub.set_label("Not installed · mullvad not on PATH")
            mv_loc_icon.set_label("—")
            mv_loc_name.set_label("Mullvad not installed")
            mv_loc_sub.set_label("Install the mullvad CLI to manage relays")
            return

        self._set_class(mv_sw, "on", mv_connected)
        self._set_class(mv_section, "off", not mv_connected)
        if mv_connected:
            mv_sub.set_label(self._short(
                f"{mv['location']} · WireGuard", 56,
            ))
        else:
            mv_sub.set_label("Not connected · WireGuard")

        preferred_disp = self.effective(
            "mullvad.preferred",
            f"{mv['country']}, {mv['city']}"
            if mv["country"] and mv["city"] else mv["preferred"],
        )
        country = mv["country"] or "—"
        mv_loc_icon.set_label(self._country_code(country))
        mv_loc_name.set_label(self._short(country, 28))
        mv_loc_sub.set_label(self._short(
            f"{mv['city']} · preferred {preferred_disp}"
            if preferred_disp else mv["city"] or "—",
            56,
        ))
