"""Bluetooth detail view: hero card + paired-device list."""

from gi.repository import GLib, Gtk

from ..actions import (
    act_bt_connect,
    act_bt_disconnect,
    act_bt_scan,
    act_open_bluetooth_settings,
)
from ..constants import G


class BluetoothViewMixin:
    def _build_bluetooth_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        sw = self._switch()
        view.append(self._detail_header("Bluetooth", right_widget=sw))

        def _on_bt_toggle(_b):
            target = not self.effective(
                "bluetooth.powered", self.state["bluetooth"]["powered"],
            )
            self._request_setting("bluetooth.powered", target, "Bluetooth")
        self._connect_switch(sw, _on_bt_toggle)

        hero = self._hero_card_ref()
        view.append(hero.widget)
        section = self._section_label("My Devices", action="Scan")
        section_btn = section.get_last_child()
        view.append(section)
        lst = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(lst)
        settings_btn = self._ghost_btn("Open Bluetooth Settings")
        view.append(settings_btn)

        def _scan_done():
            section_btn.set_label("Scan")
            self._tick_slow()
            return False

        def _open_blueman():
            self._hide_window()
            act_open_bluetooth_settings()

        def _on_scan(_b):
            if not self.effective("bluetooth.powered", self.state["bluetooth"]["powered"]):
                return
            section_btn.set_label("Scanning...")
            act_bt_scan()
            GLib.timeout_add(1800, _scan_done)
            _open_blueman()
        section_btn.connect("clicked", _on_scan)
        settings_btn.connect("clicked", lambda _b: _open_blueman())

        def refresh(s):
            b = s["bluetooth"]
            powered = self.effective("bluetooth.powered", b["powered"])
            self._set_class(sw, "on", powered)
            lst.set_sensitive(powered)

            if b["primary"]:
                p = b["primary"]
                hero.icon.set_label(self._bt_icon_glyph(p.get("icon")))
                hero.title.set_label(self._short(p["alias"], 26))
                addr = p.get("address", "")
                hero.sub.set_label(
                    self._short(f"Connected · {addr}", 56)
                )
                if p.get("battery") is not None:
                    hero.big.set_label(f"{p['battery']}%")
                    hero.small.set_label("battery")
                else:
                    hero.big.set_label("●")
                    hero.small.set_label("active")
            elif not b["powered"]:
                hero.icon.set_label(G["bluetooth"])
                hero.title.set_label("Bluetooth off")
                hero.sub.set_label("Enable to pair devices")
                hero.big.set_label("—")
                hero.small.set_label("")
            else:
                hero.icon.set_label(G["bluetooth_on"])
                hero.title.set_label("No device connected")
                n = len(b["devices"])
                hero.sub.set_label(
                    f"{n} paired device{'s' if n != 1 else ''}"
                )
                hero.big.set_label(str(n))
                hero.small.set_label("paired")

            if not self._list_changed(lst, b["devices"]):
                return
            self._clear(lst)
            if not b["devices"]:
                lst.append(self._drawer_item(
                    G["plus"], "No paired devices",
                    "Put your device in pairing mode", "—",
                    subtle=True,
                ))
            else:
                for d in b["devices"]:
                    bat = d.get("battery")
                    sub_parts = []
                    if d.get("icon"):
                        sub_parts.append(d["icon"].replace("-", " "))
                    if bat is not None:
                        sub_parts.append(f"{bat}%")
                    if not d["connected"]:
                        sub_parts.append("offline")
                    row = self._drawer_item(
                        self._bt_icon_glyph(d.get("icon")),
                        self._short(d["alias"], 24),
                        " · ".join(sub_parts) or "—",
                        "Connected" if d["connected"] else "Connect",
                        active=d["connected"],
                    )
                    row._item_key = d["address"]

                    def _on_dev_click(_b, addr=d["address"],
                                      currently=d["connected"]):
                        key = f"bluetooth.dev.{addr}"
                        target = not currently
                        self._pending_set(key, target, ttl_s=8)
                        if target:
                            act_bt_connect(addr)
                        else:
                            act_bt_disconnect(addr)
                    row.connect("clicked", _on_dev_click)
                    lst.append(row)
            pair = self._drawer_item(
                G["plus"], "Pair new device",
                "Put your device in pairing mode", "›", subtle=True,
            )
            pair.connect("clicked", lambda _b: _open_blueman())
            lst.append(pair)
            self._restore_list_focus(lst)

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
