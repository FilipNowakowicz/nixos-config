"""Microphone detail view: input gain, mute and input-source picker."""

from gi.repository import Gtk

from ..actions import (
    act_open_sound_settings,
)
from ..constants import G


class MicrophoneViewMixin:
    def _build_microphone_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        mute_btn = self._icon_btn(G["mic"])
        def _on_mic_mute(_b):
            target = not self.effective("audio.source_muted", self.state["audio"]["source_muted"])
            self._request_setting("audio.source_muted", target, "Microphone mute")
        mute_btn.connect("clicked", _on_mic_mute)
        view.append(self._detail_header("Microphone", right_widget=mute_btn))
        hero = self._hero_card_ref()
        view.append(hero.widget)
        main = self._box(Gtk.Orientation.VERTICAL, spacing=12,
                         css=["surface", "slider-block"])
        slider = self._slider_row(G["mic"])
        main.append(slider.widget)
        view.append(main)
        self._bind_setting_slider(slider, "audio.source_volume_pct", "Microphone level")
        slider.glyph_btn.connect("clicked", _on_mic_mute)

        view.append(self._section_label("Input Devices"))
        inp = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(inp)

        settings_btn = self._ghost_btn("Open Sound Settings")

        def _open_pavucontrol(_b):
            self._hide_window()
            act_open_sound_settings()
        settings_btn.connect("clicked", _open_pavucontrol)
        view.append(settings_btn)

        def refresh(s):
            a = s["audio"]
            muted = self.effective("audio.source_muted", a["source_muted"])
            mute_btn.set_label(G["mic_off"] if muted else G["mic"])
            self._name_control(mute_btn, "Unmute microphone" if muted else "Mute microphone")

            hero.icon.set_label(G["mic_off"] if muted else G["mic"])
            hero.title.set_label(self._short(a["source_name"], 28))
            hero.sub.set_label("Default input")
            hero.big.set_label(str(a["source_volume_pct"]))
            hero.small.set_label("muted" if muted else "level")

            self._set_slider_polled(slider, self.effective("audio.source_volume_pct", a["source_volume_pct"]))
            slider.glyph_btn.set_label(G["mic_off"] if muted else G["mic"])
            self._name_control(slider.glyph_btn, "Unmute microphone" if muted else "Mute microphone")

            key = "audio.default_source"
            self.effective(key, a.get("source_node_name"))
            request = self._settings.requests.get(key)
            pending = request is not None and request.phase in ("writing", "confirming")
            snapshot = {"devices": a["sources"], "intent": request.target if pending else None}
            if not self._list_changed(inp, snapshot):
                return
            self._clear(inp)
            if not a["sources"]:
                inp.append(self._drawer_item(
                    G["mic"], "No input devices", "—", "—", subtle=True,
                ))
            for device in a["sources"]:
                switching = pending and request.target == device.get("name")
                row = self._drawer_item(
                    G["mic"], self._short(device["desc"], 28),
                    "Switching…" if switching else "Audio input",
                    "Waiting" if switching else "Active" if device["default"] else "Switch",
                    active=device["default"],
                )
                row._item_key = device.get("name")
                def switch(_button, name=device.get("name")):
                    current = next((d for d in self.state["audio"]["sources"] if d.get("name") == name), None)
                    if current is not None and name:
                        self._request_setting(key, name, "Microphone device")
                row.connect("clicked", switch)
                inp.append(row)
            self._restore_list_focus(inp)

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
