"""Do Not Disturb detail view: switch + timed-revert presets."""

import time

from gi.repository import GLib, Gtk

from ..actions import act_open_notification_config, act_set_dnd_mode
from ..constants import G


class DndViewMixin:
    def _build_dnd_view(self):
        available = self.state.get("caps", {}).get("dnd", True)
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        sw = self._switch()
        sw.set_sensitive(available)
        view.append(self._detail_header("Do Not Disturb", right_widget=sw))

        def _on_dnd_toggle(_b):
            target_enabled = not self.effective(
                "dnd.enabled", self.state["dnd"]["enabled"],
            )
            self._pending_set("dnd.enabled", target_enabled, ttl_s=3)
            self._set_class(sw, "on", target_enabled)
            act_set_dnd_mode("do-not-disturb" if target_enabled else "default")
        sw.connect("clicked", _on_dnd_toggle)

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
        # that fires `mode -s default` after the duration.
        def _enable_for(seconds, label=None):
            self._pending_set("dnd.enabled", True, ttl_s=3)
            self._set_class(sw, "on", True)
            act_set_dnd_mode("do-not-disturb")
            if seconds and seconds > 0:
                def _revert():
                    self._pending_set("dnd.enabled", False, ttl_s=3)
                    self._set_class(sw, "on", False)
                    act_set_dnd_mode("default")
                    return False
                GLib.timeout_add_seconds(int(seconds), _revert)

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
