"""Do Not Disturb detail view: switch + timed-revert presets."""

import time

from gi.repository import GLib, Gtk

from ..actions import act_open_notification_config
from ..constants import G


class DndViewMixin:
    def _build_dnd_view(self):
        available = self.state.get("caps", {}).get("dnd", True)
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        sw = self._switch()
        sw.set_sensitive(available)
        view.append(self._detail_header("Do Not Disturb", right_widget=sw))
        self._dnd_timer_id = 0

        def cancel_timer():
            if self._dnd_timer_id:
                GLib.source_remove(self._dnd_timer_id)
                self._dnd_timer_id = 0

        def _on_dnd_toggle(_b):
            cancel_timer()
            target_enabled = not self.effective(
                "dnd.enabled", self.state["dnd"]["enabled"],
            )
            self._request_setting("dnd.enabled", target_enabled, "Do Not Disturb")
        self._connect_switch(sw, _on_dnd_toggle)

        wrap = self._box(Gtk.Orientation.VERTICAL, spacing=8, css="surface")
        prompt = (
            "Silence notifications until…" if available
            else "Mako not installed · notification control unavailable"
        )
        wrap.append(self._label(prompt, "dnd-prompt"))
        seg = self._segmented([
            (G["clock"], "1 hour"),
            (G["sun"], "8 am"),
            (G["bell_off"], "Always"),
        ], click_visual=True)
        seg.widget.set_sensitive(available)
        wrap.append(seg.widget)
        view.append(wrap)

        # The three preset buttons all enable DND; mako has no native
        # time-bound mode, so the timed presets schedule a GLib timeout
        # that fires `mode -r do-not-disturb` after the duration.
        def _enable_for(seconds, label=None):
            cancel_timer()
            self._request_setting("dnd.enabled", True, "Do Not Disturb")
            if seconds and seconds > 0:
                def _revert():
                    self._dnd_timer_id = 0
                    self._request_setting("dnd.enabled", False, "Do Not Disturb")
                    return False
                self._dnd_timer_id = GLib.timeout_add_seconds(int(seconds), _revert)

        def _seconds_until_8am():
            now = time.localtime()
            now_s = now.tm_hour * 3600 + now.tm_min * 60 + now.tm_sec
            target = 8 * 3600
            if now_s < target:
                return target - now_s
            return (24 * 3600 - now_s) + target

        seg.buttons[0].connect("clicked", lambda _b: _enable_for(3600))
        seg.buttons[1].connect("clicked", lambda _b: _enable_for(_seconds_until_8am()))
        seg.buttons[2].connect("clicked", lambda _b: _enable_for(0))

        notif_btn = self._ghost_btn("Edit Notification Rules")
        notif_btn.connect("clicked", lambda _b: (
            self._hide_window(), act_open_notification_config(),
        ))
        view.append(notif_btn)

        def refresh(s):
            self._set_class(sw, "on", self.effective(
                "dnd.enabled", s["dnd"]["enabled"],
            ))

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
