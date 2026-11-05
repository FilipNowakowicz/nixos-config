"""Volume detail view: hero card, slider, output-sink picker."""

from gi.repository import Gtk

from ..actions import (
    act_open_sound_settings,
    act_set_default_sink,
)
from ..constants import G


class VolumeViewMixin:
    def _build_volume_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        mute_btn = self._icon_btn(G["volume"])
        def _on_vol_mute(_b):
            target = not self.effective("audio.sink_muted", self.state["audio"]["sink_muted"])
            self._request_setting("audio.sink_muted", target, "Output mute")
        mute_btn.connect("clicked", _on_vol_mute)
        view.append(self._detail_header("Volume", right_widget=mute_btn))
        hero = self._hero_card_ref()
        view.append(hero.widget)
        main = self._box(Gtk.Orientation.VERTICAL, spacing=12,
                         css=["surface", "slider-block"])
        slider = self._slider_row(G["volume"])
        main.append(slider.widget)
        view.append(main)
        self._bind_setting_slider(slider, "audio.sink_volume_pct", "Volume")
        slider.glyph_btn.connect("clicked", _on_vol_mute)

        view.append(self._section_label("Output Devices"))
        out = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(out)
        settings_btn = self._ghost_btn("Open Sound Settings")

        def _open_pavucontrol(_b):
            self._hide_window()
            act_open_sound_settings()
        settings_btn.connect("clicked", _open_pavucontrol)
        view.append(settings_btn)

        def refresh(s):
            a = s["audio"]
            muted = self.effective("audio.sink_muted", a["sink_muted"])
            mute_btn.set_label(G["volume_mute"] if muted else G["volume"])
            self._name_control(mute_btn, "Unmute audio" if muted else "Mute audio")

            hero.icon.set_label(self._sink_icon_glyph(a["sink_name"]))
            hero.title.set_label(self._short(a["sink_name"], 28))
            hero.sub.set_label("default sink")
            hero.big.set_label(str(a["sink_volume_pct"]))
            hero.small.set_label("muted" if muted else "level")

            self._set_slider_polled(slider, self.effective("audio.sink_volume_pct", a["sink_volume_pct"]))
            slider.glyph_btn.set_label(G["volume_mute"] if muted else G["volume"])
            self._name_control(slider.glyph_btn, "Unmute audio" if muted else "Mute audio")

            if not self._list_changed(out, a["sinks"]):
                return
            self._clear(out)
            if not a["sinks"]:
                out.append(self._drawer_item(
                    G["volume"], "No output devices", "—", "—",
                    subtle=True,
                ))
            else:
                for sink in a["sinks"]:
                    row = self._drawer_item(
                        self._sink_icon_glyph(sink["desc"]),
                        self._short(sink["desc"], 28),
                        f"id {sink['id']}",
                        "Active" if sink["default"] else "Switch",
                        active=sink["default"],
                    )
                    row._item_key = sink["id"]
                    if not sink["default"]:
                        def _switch(_b, sid=sink["id"]):
                            act_set_default_sink(sid)
                        row.connect("clicked", _switch)
                    out.append(row)
            self._restore_list_focus(out)

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
