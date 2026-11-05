"""Bluetooth detail view: hero card + paired-device list."""

from gi.repository import Gtk

from ..actions import (
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
        view.append(self._section_label("My Devices"))
        lst = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(lst)
        settings_btn = self._ghost_btn("Open Bluetooth Settings")
        view.append(settings_btn)
        launch_error = self._label("Couldn’t open Bluetooth Settings. Try again.")
        launch_error.set_wrap(True)
        launch_error.set_visible(False)
        view.append(launch_error)

        def _open_blueman():
            if act_open_bluetooth_settings():
                launch_error.set_visible(False)
                self._hide_window()
            else:
                launch_error.set_visible(True)
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

            devices = []
            for device in b["devices"]:
                key = "bluetooth.device." + device["address"]
                intent = self.effective(key, device["connected"])
                request = self._settings.requests.get(key)
                pending = request is not None and request.phase in ("writing", "confirming")
                devices.append({**device, "intent": intent, "pending": pending})
            present = {"bluetooth.device." + device["address"] for device in b["devices"]}
            for key in self._settings.requests:
                if key.startswith("bluetooth.device.") and key not in present:
                    self.effective(key, None)
            if not self._list_changed(lst, devices):
                return
            self._clear(lst)
            if not b["devices"]:
                lst.append(self._drawer_item(
                    G["plus"], "No paired devices",
                    "Put your device in pairing mode", "—",
                    subtle=True,
                ))
            else:
                for d in devices:
                    bat = d.get("battery")
                    sub_parts = []
                    if d.get("icon"):
                        sub_parts.append(d["icon"].replace("-", " "))
                    if bat is not None:
                        sub_parts.append(f"{bat}%")
                    if d["pending"]:
                        sub_parts.append("Connecting…" if d["intent"] else "Disconnecting…")
                    elif not d["connected"]:
                        sub_parts.append("offline")
                    row = self._drawer_item(
                        self._bt_icon_glyph(d.get("icon")),
                        self._short(d["alias"], 24),
                        " · ".join(sub_parts) or "—",
                        "Disconnect" if d["intent"] else "Connect",
                        active=d["connected"],
                    )
                    row._item_key = d["address"]

                    def _on_dev_click(_b, addr=d["address"]):
                        current = next((item for item in self.state["bluetooth"]["devices"]
                                        if item["address"] == addr), None)
                        if current is None:
                            return
                        key = "bluetooth.device." + addr
                        target = not self.effective(key, current["connected"])
                        self._request_setting(key, target, "Bluetooth connection")
                    row.connect("clicked", _on_dev_click)
                    lst.append(row)
            pair = self._drawer_item(
                G["plus"], "Pair new device",
                "Opens Bluetooth Settings", "›", subtle=True,
            )
            pair.connect("clicked", lambda _b: _open_blueman())
            lst.append(pair)
            self._restore_list_focus(lst)

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
