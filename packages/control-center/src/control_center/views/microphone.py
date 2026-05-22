"""Microphone detail view: hero card, slider, decorative meter, input-source picker."""

from gi.repository import Gtk

from ..actions import (
    act_open_sound_settings,
    act_set_default_source,
    act_set_source_volume,
    act_toggle_source_mute,
)
from ..constants import G


class MicrophoneViewMixin:
    def _build_microphone_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        mute_btn = self._icon_btn(G["mic"])
        def _on_mic_mute(_b):
            self._pending_set("audio.source_muted",
                              not self.state["audio"]["source_muted"], ttl_s=2)
            act_toggle_source_mute()
        mute_btn.connect("clicked", _on_mic_mute)
        view.append(self._detail_header("Microphone", right_widget=mute_btn))
        hero = self._hero_card_ref()
        view.append(hero.widget)
        main = self._box(Gtk.Orientation.VERTICAL, spacing=12,
                         css=["surface", "slider-block"])
        slider = self._slider_row(G["mic"])
        main.append(slider.widget)
        view.append(main)
        self._bind_slider(slider, act_set_source_volume)
        slider.glyph_btn.connect("clicked", _on_mic_mute)

        view.append(self._section_label("Input Level", action="Test"))
        meter = self._box(Gtk.Orientation.HORIZONTAL, spacing=3, css="level-meter")
        # Static visual decor: real-time peak metering requires PipeWire stream
        # subscription, out of scope for the read-only data pass.
        levels = [22, 38, 58, 72, 48, 32, 56, 44, 28, 36, 22, 16]
        active = [True] * 8 + [False] * 4
        for h, on in zip(levels, active):
            bar = Gtk.Box()
            bar.add_css_class("meter-bar")
            if on:
                bar.add_css_class("active")
            bar.set_size_request(-1, int(h * 0.42))
            bar.set_valign(Gtk.Align.END)
            bar.set_hexpand(True)
            meter.append(bar)
        view.append(meter)

        view.append(self._section_label("Input Devices", action="Detect"))
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

            hero.icon.set_label(G["mic_off"] if muted else G["mic"])
            hero.title.set_label(self._short(a["source_name"], 28))
            hero.sub.set_label("default source")
            hero.big.set_label(str(a["source_volume_pct"]))
            hero.small.set_label("muted" if muted else "level")

            self._set_slider_polled(slider, a["source_volume_pct"])
            slider.glyph_btn.set_label(G["mic_off"] if muted else G["mic"])

            self._clear(inp)
            if not a["sources"]:
                inp.append(self._drawer_item(
                    G["mic"], "No input devices", "—", "—", subtle=True,
                ))
            else:
                for src in a["sources"]:
                    row = self._drawer_item(
                        G["mic"],
                        self._short(src["desc"], 28),
                        f"id {src['id']}",
                        "Active" if src["default"] else "Switch",
                        active=src["default"],
                    )
                    if not src["default"]:
                        def _switch(_b, sid=src["id"]):
                            act_set_default_source(sid)
                        row.connect("clicked", _switch)
                    inp.append(row)

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
