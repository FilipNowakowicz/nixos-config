"""Control Center GTK application.

Holds the lifecycle (window, tick loops, navigation), the reusable widget
primitives (label/box/tile/chip/slider/drawer/...), and the pending-write
override machinery. View-specific build methods live in ``views/*`` mixins
and are mixed in here.
"""

import os
import signal
import subprocess
import threading
import time
from copy import deepcopy
from types import SimpleNamespace

from gi.repository import Gdk, GLib, Gtk, Gtk4LayerShell, Pango

from .constants import (
    BATTERY_LEVELS,
    FAST_STATE_KEYS,
    G,
    PANEL_CONTENT_WIDTH,
    PANEL_MARGIN,
    PANEL_PADDING,
    PANEL_TOTAL_WIDTH,
    SLOW_STATE_KEYS,
    VIEWS,
)
from .css import build_css
from .gather import gather_fast_state, gather_slow_state
from .state_file import clear_state, read_state, write_state
from .settings import OrderedWriter, Settings, command_for
from .theme import load_colors
from .views.bluetooth import BluetoothViewMixin
from .views.dnd import DndViewMixin
from .views.home import HomeViewMixin
from .views.microphone import MicrophoneViewMixin
from .views.vpn import VpnViewMixin
from .views.volume import VolumeViewMixin
from .views.wifi import WifiViewMixin


class ControlCenter(
    Gtk.Application,
    HomeViewMixin,
    WifiViewMixin,
    BluetoothViewMixin,
    VpnViewMixin,
    DndViewMixin,
    VolumeViewMixin,
    MicrophoneViewMixin,
):
    FAST_POLL_MS = 2000
    SLOW_POLL_MS = 5000
    PENDING_TTL_S = 6

    def __init__(self, initial_view, colors, state, start_hidden=False):
        super().__init__(application_id="io.personal.control-center")
        self.initial_view = initial_view
        self._current_view = initial_view
        self._visible = not start_hidden
        self._dismiss_armed = False
        self.colors = colors
        self._css_provider = None
        self.state = state
        self.win = None
        self.stack = None
        self._revealer = None
        self._refreshers = []
        self._fast_poll_id = 0
        self._slow_poll_id = 0
        self._reveal_source_id = 0
        self._dismiss_source_id = 0
        self._theme_reload_signal_id = 0
        self._fast_gathering = False
        self._slow_gathering = False
        # Optimistic overrides while slow writes (e.g. tailscale up) catch up.
        # key -> (target_value, expires_at)
        self._pending = {}
        self._settings = Settings()
        self._writer = OrderedWriter()
        self._observed_at = {}
        self._write_status = None
        self._gtk_settings = None
        self._motion_signal_id = 0
        self._reduced_motion = False
        self.connect("activate", self._build)
        self.connect("shutdown", self._on_shutdown)

    # ── Window + stack ────────────────────────────────────────

    def _build(self, _app):
        self._gtk_settings = Gtk.Settings.get_default()
        if self._gtk_settings is not None:
            self._reduced_motion = not self._gtk_settings.get_property("gtk-enable-animations")
            self._motion_signal_id = self._gtk_settings.connect("notify::gtk-enable-animations", self._sync_motion)
        self._install_css_provider()

        self.win = Gtk.ApplicationWindow(application=self)
        self.win.set_decorated(False)
        self.win.set_title("Control Centre")
        # Resizable must stay True: the four-edge-anchored layer surface needs
        # to be stretched to fill the output. set_resizable(False) pins it to the
        # content size, which breaks the full-surface click-outside catcher.
        self.win.connect("close-request", self._on_close_request)

        Gtk4LayerShell.init_for_window(self.win)
        Gtk4LayerShell.set_layer(self.win, Gtk4LayerShell.Layer.OVERLAY)
        # Anchor all four edges so the layer surface fills the whole output, and
        # extend over any exclusive zones (waybar) with exclusive_zone = -1. The
        # panel itself is pinned top-right via child alignment + margins; the
        # rest of the surface is transparent and exists only to catch a click
        # *outside* the panel (click-to-dismiss). A panel-sized surface can't
        # see outside clicks, and under focus-follows-mouse a focus-leave dismiss
        # fires on hover — so we dismiss on an explicit outside click instead.
        for _edge in (
            Gtk4LayerShell.Edge.TOP, Gtk4LayerShell.Edge.RIGHT,
            Gtk4LayerShell.Edge.BOTTOM, Gtk4LayerShell.Edge.LEFT,
        ):
            Gtk4LayerShell.set_anchor(self.win, _edge, True)
        Gtk4LayerShell.set_exclusive_zone(self.win, -1)
        # ON_DEMAND keyboard: the panel takes focus while open so Escape works.
        Gtk4LayerShell.set_keyboard_mode(
            self.win, Gtk4LayerShell.KeyboardMode.ON_DEMAND
        )
        Gtk4LayerShell.set_namespace(self.win, "control-center")

        key = Gtk.EventControllerKey()
        key.connect("key-pressed", self._on_key)
        self.win.add_controller(key)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT)
        self.stack.set_transition_duration(0 if self._reduced_motion else 180)
        self.stack.set_size_request(PANEL_CONTENT_WIDTH, -1)
        # Height follows the visible view, not the tallest one — otherwise the
        # compact home view is padded down to the VPN view's height, leaving
        # dead space at the bottom of the panel.
        self.stack.set_vhomogeneous(False)

        self.stack.add_named(self._build_home_view(), "home")
        self.stack.add_named(self._build_wifi_view(), "wifi")
        self.stack.add_named(self._build_bluetooth_view(), "bluetooth")
        self.stack.add_named(self._build_vpn_view(), "vpn")
        self.stack.add_named(self._build_dnd_view(), "dnd")
        self.stack.add_named(self._build_volume_view(), "volume")
        self.stack.add_named(self._build_microphone_view(), "microphone")
        self.stack.set_visible_child_name(self.initial_view)
        self._scroller = Gtk.ScrolledWindow()
        self._scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self._scroller.set_propagate_natural_height(True)
        self._scroller.set_min_content_height(1)
        self._scroller.set_child(self.stack)
        self.stack.connect("notify::visible-child-name", lambda *_: self._scroller.get_vadjustment().set_value(0))
        self._sync_panel_height()
        self.win.connect("realize", self._bind_surface_size)

        # Entrance animation: a CROSSFADE revealer fades the panel content in on
        # every show. CROSSFADE (not a slide) keeps the panel at full size during
        # the transition, so the click-outside bounds stay correct and there's no
        # layout jump; the surface-level drop is handled by the compositor's
        # `animation = layers` rule (see hyprland.conf). Toggled via _reveal_panel
        # on show and reset to hidden on hide so the next show re-animates.
        self._revealer = Gtk.Revealer()
        self._revealer.set_transition_type(Gtk.RevealerTransitionType.CROSSFADE)
        self._revealer.set_transition_duration(0 if self._reduced_motion else 240)
        self._revealer.set_child(self._scroller)
        self._revealer.set_reveal_child(False)

        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        panel.set_name("panel")
        panel.set_size_request(PANEL_TOTAL_WIDTH, -1)
        panel.set_halign(Gtk.Align.END)
        panel.set_valign(Gtk.Align.START)
        panel.set_margin_top(PANEL_MARGIN)
        panel.set_margin_end(PANEL_MARGIN)
        panel.append(self._revealer)
        self._write_status = self._box(Gtk.Orientation.HORIZONTAL, spacing=8, css="write-status")
        self._write_status_label = self._label("")
        self._write_status_label.set_wrap(True)
        self._write_status_label.set_max_width_chars(28)
        self._write_status_label.set_hexpand(True)
        self._write_retry = Gtk.Button(label="Retry")
        self._write_retry.connect("clicked", self._retry_setting)
        self._write_status.append(self._write_status_label)
        self._write_status.append(self._write_retry)
        self._write_status.set_visible(False)
        panel.append(self._write_status)

        # Transparent full-surface root: pins the panel top-right and dismisses
        # the window when a click lands outside the panel's bounds.
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.set_name("cc-root")
        root.set_hexpand(True)
        root.set_vexpand(True)
        root.append(panel)

        outside = Gtk.GestureClick()
        outside.set_button(0)  # listen on any button

        def _on_outside_press(gesture, _n_press, x, y):
            ok, rect = panel.compute_bounds(root)
            inside = ok and (
                rect.origin.x <= x <= rect.origin.x + rect.size.width
                and rect.origin.y <= y <= rect.origin.y + rect.size.height
            )
            if inside:
                # Bow out so the panel's own buttons / slider-drag gestures
                # own the press; never compete with inner widgets.
                gesture.set_state(Gtk.EventSequenceState.DENIED)
                return
            if self._visible and self._dismiss_armed:
                self._hide_window()
        outside.connect("pressed", _on_outside_press)
        root.add_controller(outside)

        self.win.set_child(root)
        if self._visible:
            self.win.present()
            self._schedule_show()
            self._set_mako_mode(True)
        else:
            self.win.set_visible(False)

        self._fast_poll_id = GLib.timeout_add(self.FAST_POLL_MS, self._tick_fast)
        self._slow_poll_id = GLib.timeout_add(self.SLOW_POLL_MS, self._tick_slow)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self._on_ipc_toggle)
        self._theme_reload_signal_id = GLib.unix_signal_add(
            GLib.PRIORITY_DEFAULT,
            signal.SIGUSR2,
            self._on_theme_reload,
        )
        self._tick_fast()  # populate visible state immediately
        self._tick_slow()  # fill network/VPN details in the background

    def _on_close_request(self, *_args):
        self._hide_window()
        return True

    def _bind_surface_size(self, _window):
        surface = self.win.get_surface()
        if surface is not None:
            surface.connect("notify::height", self._sync_panel_height)
        self._sync_panel_height()

    def _sync_panel_height(self, *_args):
        surface = self.win.get_surface()
        height = surface.get_height() if surface is not None else 0
        if height <= 1:
            monitors = self.win.get_display().get_monitors()
            height = monitors.get_item(0).get_geometry().height if monitors.get_n_items() else 720
        # Reserve room for the setting status and its Retry action. Short views
        # retain their natural size; long ones scroll inside the output bounds.
        limit = max(80, height - 2 * PANEL_MARGIN - 2 * PANEL_PADDING - 64)
        if self._scroller.get_max_content_height() != limit:
            self._scroller.set_max_content_height(limit)

    def _arm_dismiss(self):
        self._dismiss_source_id = 0
        self._dismiss_armed = self._visible
        return False  # one-shot

    def _reveal_panel(self):
        self._reveal_source_id = 0
        # Flip the revealer open one tick after present() so the CROSSFADE
        # actually animates (a value set while the surface maps is treated as
        # the initial state and plays no transition).
        if self._visible and self._revealer is not None:
            self._revealer.set_reveal_child(True)
        return False  # one-shot

    def _cancel_show(self):
        for name in ("_reveal_source_id", "_dismiss_source_id"):
            source = getattr(self, name)
            if source:
                GLib.source_remove(source)
                setattr(self, name, 0)

    def _schedule_show(self):
        self._cancel_show()
        self._reveal_source_id = GLib.timeout_add(10, self._reveal_panel)
        self._dismiss_source_id = GLib.timeout_add(250, self._arm_dismiss)

    def _set_mako_mode(self, on):
        """Add/remove the mako `cc-open` mode so notifications re-anchor away
        from the panel while it's open (see home/theme/mako-config.template).
        Fire-and-forget: never block the UI or fail if mako isn't running."""
        action = "-a" if on else "-r"
        try:
            subprocess.Popen(
                ["makoctl", "mode", action, "cc-open"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass

    def _on_shutdown(self, *_args):
        self._cancel_show()
        if self._motion_signal_id:
            self._gtk_settings.disconnect(self._motion_signal_id)
            self._motion_signal_id = 0
        if getattr(self, "_dnd_timer_id", 0):
            GLib.source_remove(self._dnd_timer_id)
            self._dnd_timer_id = 0
        if self._fast_poll_id:
            GLib.source_remove(self._fast_poll_id)
            self._fast_poll_id = 0
        if self._slow_poll_id:
            GLib.source_remove(self._slow_poll_id)
            self._slow_poll_id = 0
        if self._theme_reload_signal_id:
            GLib.source_remove(self._theme_reload_signal_id)
            self._theme_reload_signal_id = 0
        # Clear the notification re-anchor mode so a dying daemon doesn't leave
        # notifications stuck in the bottom-right corner.
        self._set_mako_mode(False)
        clear_state(os.getpid())

    def _on_key(self, _ctrl, keyval, _keycode, _state):
        if keyval == Gdk.KEY_Escape:
            if self.stack.get_visible_child_name() != "home":
                self.go_back()
                return True
            self._hide_window()
            return True
        return False

    def _write_presence(self):
        write_state(os.getpid(), self._current_view, self._visible)

    def _show_window(self):
        if self.win is None or self._visible:
            return
        self._visible = True
        self._dismiss_armed = False
        self._revealer.set_reveal_child(False)
        self.win.present()
        self._schedule_show()
        self._set_mako_mode(True)
        self._write_presence()
        self._tick_fast()
        self._tick_slow()

    def _hide_window(self):
        if self.win is None:
            return
        self._visible = False
        self._dismiss_armed = False
        self._cancel_show()
        self._revealer.set_reveal_child(False)
        self.win.set_visible(False)
        self._set_mako_mode(False)
        self._write_presence()

    def _on_ipc_toggle(self):
        state = read_state()
        view = state.get("view", "home")
        if view in VIEWS:
            self.stack.set_visible_child_name(view)
            self._current_view = view
        if state.get("visible", True):
            self._show_window()
        else:
            self._hide_window()
        return True

    def _on_theme_reload(self):
        self._refresh_theme_css(force=True)
        self._tick_fast()
        return True

    # ── Refresh loop ──────────────────────────────────────────

    def _tick_fast(self):
        if not self._visible:
            return True
        if self._fast_gathering:
            return True
        self._fast_gathering = True
        previous = self.state
        started_at = time.monotonic()
        def _worker():
            try:
                state = gather_fast_state(previous)
            except Exception:
                state = None
            GLib.idle_add(self._apply_fast_state, state, started_at)
        threading.Thread(target=_worker, daemon=True).start()
        return True

    def _tick_slow(self):
        if not self._visible:
            return True
        if self._slow_gathering:
            return True
        self._slow_gathering = True
        previous = self.state
        started_at = time.monotonic()
        def _worker():
            try:
                state = gather_slow_state(previous)
            except Exception:
                state = None
            GLib.idle_add(self._apply_slow_state, state, started_at)
        threading.Thread(target=_worker, daemon=True).start()
        return True

    def _apply_fast_state(self, state, started_at=None):
        self._fast_gathering = False
        self._refresh_theme_css()
        return self._apply_state(state, FAST_STATE_KEYS, started_at)

    def _apply_slow_state(self, state, started_at=None):
        self._slow_gathering = False
        return self._apply_state(state, SLOW_STATE_KEYS, started_at)

    def _refresh_ui(self):
        for fn in self._refreshers:
            try:
                fn(self.state)
            except Exception:
                pass
        self._refresh_write_status()
        return False

    def _apply_state(self, state, keys=None, started_at=None):
        if state is None:
            return False
        for key in state if keys is None else keys:
            if key in state:
                self._observed_at[key] = started_at if started_at is not None else time.monotonic()
        if keys is None:
            self.state = state
        else:
            self.state = {
                **self.state,
                **{key: state[key] for key in keys if key in state},
            }
        self._refresh_ui()
        return False

    def _install_css_provider(self):
        display = Gdk.Display.get_default()
        if display is None:
            return
        if self._css_provider is not None:
            Gtk.StyleContext.remove_provider_for_display(
                display,
                self._css_provider,
            )
        self._css_provider = Gtk.CssProvider()
        css = build_css(self.colors)
        if self._reduced_motion:
            css += "\n* { transition-duration: 0s; animation-duration: 0s; }\n"
        self._css_provider.load_from_data(css.encode())
        Gtk.StyleContext.add_provider_for_display(
            display,
            self._css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _sync_motion(self, *_args):
        self._reduced_motion = not self._gtk_settings.get_property("gtk-enable-animations")
        self.stack.set_transition_duration(0 if self._reduced_motion else 180)
        self._revealer.set_transition_duration(0 if self._reduced_motion else 240)
        self._install_css_provider()

    def _refresh_theme_css(self, force=False):
        colors = load_colors()
        if not force and colors == self.colors:
            return
        self.colors = colors
        self._install_css_provider()

    @staticmethod
    def _set_class(widget, klass, on):
        if (klass == "on" and isinstance(widget, Gtk.Switch)
                and (widget.get_state() != bool(on) or widget.get_active() != bool(on))):
            # Even setting the same state can interrupt a native switch's
            # pointer animation before it emits notify::active.
            widget._updating = True
            try:
                widget.set_state(bool(on))
                widget.set_active(bool(on))
            finally:
                widget._updating = False
        if on:
            if not widget.has_css_class(klass):
                widget.add_css_class(klass)
        else:
            if widget.has_css_class(klass):
                widget.remove_css_class(klass)

    @staticmethod
    def _clear(container):
        child = container.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            container.remove(child)
            child = nxt

    @staticmethod
    def _list_changed(container, contents):
        """Keep live rows (and keyboard focus) when a poll changes no content."""
        if getattr(container, "_contents", None) == contents:
            return False
        container._contents = deepcopy(contents)
        container._focus_restore = None
        root = container.get_root()
        focused = root.get_focus() if isinstance(root, Gtk.Window) else None
        row = focused
        while row is not None and row.get_parent() is not container:
            row = row.get_parent()
        if row is not None:
            index, child = 0, container.get_first_child()
            while child is not None and child is not row:
                index += 1
                child = child.get_next_sibling()
            container._focus_restore = (getattr(row, "_item_key", None), index)
        return True

    @staticmethod
    def _restore_list_focus(container):
        restore = getattr(container, "_focus_restore", None)
        if restore is None:
            return
        container._focus_restore = None
        key, index = restore
        rows, child = [], container.get_first_child()
        while child is not None:
            rows.append(child)
            child = child.get_next_sibling()
        if rows:
            target = next((row for row in rows if key is not None
                           and getattr(row, "_item_key", None) == key), rows[min(index, len(rows) - 1)])
            target.grab_focus()

    # ── Pending overrides for slow writes ─────────────────────

    def _request_setting(self, key, target, label):
        command = command_for(key, target)
        token = self._settings.begin(key, target, label)
        self._writer.submit(key, token, command,
                            lambda *args: GLib.idle_add(self._setting_done, *args))
        self._refresh_ui()

    def _setting_done(self, key, token, outcome, completed_at):
        if self._settings.complete(key, token, outcome, completed_at):
            self._refresh_ui()
            self._tick_fast()
            self._tick_slow()
        return False

    def _retry_setting(self, _button):
        latest = self._settings.latest()
        if latest and latest[1].phase in ("failed", "unknown"):
            key, request = latest
            self._request_setting(key, request.target, request.label)

    def _refresh_write_status(self):
        if self._write_status is None:
            return
        latest = self._settings.latest()
        self._write_status.set_visible(latest is not None)
        if latest is None:
            return
        _key, request = latest
        text = {
            "writing": f"Updating {request.label}…",
            "confirming": f"Waiting for {request.label}…",
            "confirmed": f"{request.label} updated",
            "failed": f"Couldn’t change {request.label}. Try again.",
            "unknown": f"Couldn’t confirm {request.label}. Check its state.",
        }[request.phase]
        self._write_status_label.set_label(text)
        self._write_retry.set_visible(request.phase in ("failed", "unknown"))

    def _pending_set(self, key, target, ttl_s=None):
        self._pending[key] = (
            target, time.time() + (ttl_s or self.PENDING_TTL_S),
        )
        GLib.idle_add(self._refresh_ui)

    def effective(self, key, polled):
        """Return the user-intended value if a pending write is in flight
        and hasn't yet been observed in the polled state; otherwise polled."""
        if key in self._settings.requests:
            return self._settings.effective(key, polled, self._observed_at.get(key.split(".")[0], 0))
        entry = self._pending.get(key)
        if entry is None:
            return polled
        target, expires_at = entry
        if time.time() > expires_at:
            del self._pending[key]
            return polled
        if polled == target:
            del self._pending[key]
            return polled
        return target

    # ── Slider drag/click/scroll binding ──────────────────────

    def _bind_setting_slider(self, slider, key, label):
        self._bind_slider(slider, lambda pct: self._request_setting(key, pct, label))

    def _bind_slider(self, slider, on_set):
        """Wire a slider SimpleNamespace to user input. on_set(pct) called
        on click/drag/scroll. Refresh ticks should call _set_slider_polled
        instead of _set_slider so they skip during active drags."""
        slider._dragging = False
        slider._updating = False
        slider._settle_until = 0

        def changed(scale):
            if slider._updating:
                return
            pct = round(scale.get_value())
            slider.value.set_label(str(pct))
            slider._settle_until = time.monotonic() + 0.4
            on_set(pct)

        slider.scale.connect("value-changed", changed)
        gesture = Gtk.GestureClick()
        gesture.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        gesture.connect("pressed", lambda *_: setattr(slider, "_dragging", True))
        gesture.connect("released", lambda *_: setattr(slider, "_dragging", False))
        gesture.connect("cancel", lambda *_: setattr(slider, "_dragging", False))
        slider.scale.add_controller(gesture)

    def _set_slider_polled(self, slider, pct):
        """Variant of _set_slider that skips when user is dragging."""
        if getattr(slider, "_dragging", False) or time.monotonic() < getattr(slider, "_settle_until", 0):
            return
        self._set_slider(slider, pct)
        slider._last_pct = int(pct)

    # ── Navigation ────────────────────────────────────────────

    def go_to(self, view):
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT)
        self.stack.set_visible_child_name(view)
        self._current_view = view
        self._write_presence()

    def go_back(self):
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_RIGHT)
        self.stack.set_visible_child_name("home")
        self._current_view = "home"
        self._write_presence()

    # ── Reusable component builders ───────────────────────────

    @staticmethod
    def _label(text, css=None, xalign=0):
        lbl = Gtk.Label(label=text, xalign=xalign)
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                lbl.add_css_class(c)
        return lbl

    @staticmethod
    def _name_control(widget, name):
        # Gtk.Button.set_label labels the button by its child glyph. That
        # relation takes precedence over an explicit accessible label.
        widget._control_name = name
        widget.set_tooltip_text(name)
        def apply(*_args):
            widget.reset_relation(Gtk.AccessibleRelation.LABELLED_BY)
            widget.update_property([Gtk.AccessibleProperty.LABEL], [widget._control_name])
        apply()
        if isinstance(widget, Gtk.Button) and not getattr(widget, "_name_handler", False):
            widget.connect("notify::label", apply)
            widget._name_handler = True

    @staticmethod
    def _center_icon(label):
        label.set_xalign(0.5)
        label.set_yalign(0.5)
        label.set_justify(Gtk.Justification.CENTER)
        label.set_halign(Gtk.Align.CENTER)
        label.set_valign(Gtk.Align.CENTER)
        return label

    @staticmethod
    def _box(orientation=Gtk.Orientation.VERTICAL, spacing=0, css=None):
        box = Gtk.Box(orientation=orientation, spacing=spacing)
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                box.add_css_class(c)
        return box

    def _divider(self):
        d = Gtk.Box()
        d.add_css_class("divider")
        return d

    def _section_label(self, text, action=None, action_cb=None):
        row = self._box(Gtk.Orientation.HORIZONTAL, css="section-label")
        row.append(self._label(text, "section-text"))
        row.append(Gtk.Box(hexpand=True))
        if action:
            btn = Gtk.Button(label=action)
            btn.add_css_class("section-action")
            if action_cb:
                btn.connect("clicked", lambda _b: action_cb())
            row.append(btn)
        return row

    def _switch(self, css=None):
        """Native switch with keyboard, pointer and checked-state semantics."""
        sw = Gtk.Switch()
        sw.set_valign(Gtk.Align.CENTER)
        sw.add_css_class("switch")
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                sw.add_css_class(c)
        return sw

    @staticmethod
    def _connect_switch(switch, callback):
        def changed(widget, _property):
            if not getattr(widget, "_updating", False):
                callback(widget)
        # Record intent before the native animation completes: a poll between
        # the click and state-set must not erase the user's request.
        switch.connect("notify::active", changed)
        switch.connect("state-set", lambda *_args: True)

    @staticmethod
    def _toggle_class(widget, klass):
        if widget.has_css_class(klass):
            widget.remove_css_class(klass)
        else:
            widget.add_css_class(klass)

    def _tile(self, title, view=None):
        """Build a tile and return a SimpleNamespace of refs."""
        btn = Gtk.Button()
        btn.add_css_class("tile")

        inner = self._box(Gtk.Orientation.VERTICAL, spacing=4)
        top = self._box(Gtk.Orientation.HORIZONTAL, css="tile-icon")
        glyph_lbl = self._center_icon(self._label("", "tile-glyph", xalign=0.5))
        top.append(glyph_lbl)
        top.append(Gtk.Box(hexpand=True))
        badge_lbl = self._label("", "tile-badge")
        badge_lbl.set_visible(False)
        top.append(badge_lbl)
        chevron = self._label(G["chevron_right"], "tile-chevron")
        top.append(chevron)
        inner.append(top)
        title_lbl = self._label(title, "tile-title")
        sub_lbl = self._label("", "tile-sub")
        inner.append(title_lbl)
        inner.append(sub_lbl)
        btn.set_child(inner)

        if view:
            btn.connect("clicked", lambda _b, v=view: self.go_to(v))
        return SimpleNamespace(
            widget=btn, glyph=glyph_lbl, title=title_lbl,
            sub=sub_lbl, badge=badge_lbl,
        )

    def _slider_row(self, glyph, aux_label=None, aux_view=None):
        """Build a slider row. Returns SimpleNamespace(widget, scale, value, aux)."""
        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=12, css="slider-row")
        row.set_hexpand(True)

        gbtn = Gtk.Label(label=glyph) if glyph == G["sun"] else Gtk.Button(label=glyph)
        gbtn.add_css_class("slider-icon" if glyph == G["sun"] else "glyph-btn")
        row.append(gbtn)

        track = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 1 if glyph == G["sun"] else 0, 100, 1)
        track.set_draw_value(False)
        track.set_hexpand(True)
        track.add_css_class("setting-scale")
        name = {G["volume"]: "Volume", G["sun"]: "Brightness", G["mic"]: "Microphone level"}.get(glyph, "Level")
        track.update_property([Gtk.AccessibleProperty.LABEL], [name])
        gbtn.set_tooltip_text(name)
        action_name = {G["volume"]: "Mute audio", G["mic"]: "Mute microphone"}.get(glyph, name)
        self._name_control(gbtn, action_name)
        row.append(track)

        val = self._label("0", "slider-value", xalign=1)
        val.set_width_chars(3)
        val.set_size_request(24, -1)
        row.append(val)

        aux = None
        aux_text = None
        if aux_label:
            aux = Gtk.Button(label=G["chevron_right"])
            aux.add_css_class("slider-aux")
            aux.set_tooltip_text(aux_label)
            self._name_control(aux, aux_label)
            if aux_view:
                aux.connect("clicked", lambda _b, v=aux_view: self.go_to(v))
            row.append(aux)
        elif glyph == G["sun"]:
            row.append(Gtk.Box(width_request=24))

        return SimpleNamespace(
            widget=row, glyph_btn=gbtn, scale=track, value=val, aux=aux,
            aux_label=aux_text,
        )

    def _set_slider(self, slider, pct):
        pct = max(0, min(100, pct))
        slider._updating = True
        try:
            slider.scale.set_value(pct)
            slider.value.set_label(str(int(pct)))
        finally:
            slider._updating = False

    @staticmethod
    def _short(name, n=22):
        if not name:
            return "—"
        return name if len(name) <= n else name[: n - 1] + "…"

    @staticmethod
    def _battery_glyph(percent, charging=False):
        if charging:
            return G["battery_charging"]
        idx = max(0, min(10, round((percent or 0) / 10)))
        return BATTERY_LEVELS[idx]

    @staticmethod
    def _wifi_glyph(signal_pct):
        if signal_pct >= 70:
            return G["wifi"]
        if signal_pct >= 50:
            return G["wifi_3"]
        if signal_pct >= 30:
            return G["wifi_2"]
        return G["wifi_1"]

    @staticmethod
    def _bt_icon_glyph(icon_hint):
        h = (icon_hint or "").lower()
        if "headset" in h or "headphone" in h or "audio" in h:
            return G["headphones"]
        if "mouse" in h or "pointing" in h:
            return G["mouse"]
        if "keyboard" in h or "input-keyboard" in h:
            return G["keyboard"]
        if "phone" in h:
            return G["phone"]
        return G["bluetooth"]

    @staticmethod
    def _sink_icon_glyph(desc):
        d = (desc or "").lower()
        if "hdmi" in d or "displayport" in d:
            return G["monitor"]
        if "bluetooth" in d or "buds" in d or "headph" in d or "wh-" in d:
            return G["headphones"]
        return G["volume"]

    @staticmethod
    def _country_code(name):
        if not name:
            return "—"
        table = {
            "united kingdom": "GB", "uk": "GB", "great britain": "GB",
            "united states": "US", "usa": "US", "u.s.a.": "US",
            "sweden": "SE", "germany": "DE", "switzerland": "CH",
            "netherlands": "NL", "france": "FR", "norway": "NO",
            "denmark": "DK", "finland": "FI", "poland": "PL",
            "spain": "ES", "italy": "IT", "ireland": "IE", "canada": "CA",
            "japan": "JP", "australia": "AU", "austria": "AT",
            "belgium": "BE", "czech republic": "CZ", "czechia": "CZ",
        }
        return table.get(name.strip().lower(), name[:2].upper())

    def _chip(self, glyph, label, on=False, css=None):
        btn = Gtk.Button()
        btn.add_css_class("chip")
        if on:
            btn.add_css_class("on")
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                btn.add_css_class(c)
        inner = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
        inner.append(self._label(glyph, "chip-glyph"))
        inner.append(self._label(label))
        btn.set_child(inner)
        btn.connect("clicked", lambda b: self._toggle_class(b, "on"))
        return btn

    def _segmented(self, options, active_idx=-1, click_visual=False):
        """options: list of (glyph, label) tuples.

        Returns SimpleNamespace(widget, buttons). If click_visual is True,
        clicking a segment flips its visual active state locally — used for
        sections that don't have backing state (DND timers). For state-bound
        segments (power profile), leave click_visual False so the periodic
        refresh stays the source of truth.
        """
        bar = self._box(Gtk.Orientation.HORIZONTAL, spacing=2, css="segmented")
        bar.set_homogeneous(True)
        buttons = []

        def select(idx):
            for i, btn in enumerate(buttons):
                if i == idx:
                    btn.add_css_class("active")
                else:
                    btn.remove_css_class("active")

        for i, (glyph, label) in enumerate(options):
            btn = Gtk.Button()
            btn.add_css_class("seg")
            if i == active_idx:
                btn.add_css_class("active")
            btn.set_hexpand(True)
            inner = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
            inner.set_halign(Gtk.Align.CENTER)
            inner.append(self._label(glyph))
            inner.append(self._label(label))
            btn.set_child(inner)
            if click_visual:
                btn.connect("clicked", lambda _b, idx=i: select(idx))
            buttons.append(btn)
            bar.append(btn)
        return SimpleNamespace(widget=bar, buttons=buttons)

    def _drawer_item(self, glyph, name, subtitle, right_text,
                     active=False, subtle=False, status=None):
        """status: None / "online" / "this" / "offline" """
        btn = Gtk.Button()
        btn.add_css_class("drawer-item")
        if active:
            btn.add_css_class("active")
        if subtle:
            btn.add_css_class("subtle")

        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=10)

        icon = self._label(glyph, "di-icon", xalign=0.5)
        self._center_icon(icon)
        icon.set_width_chars(2)
        icon.set_valign(Gtk.Align.CENTER)
        row.append(icon)

        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        copy.append(self._label(name, "di-name"))
        if subtitle:
            copy.append(self._label(subtitle, "di-sub"))
        row.append(copy)

        right = self._box(Gtk.Orientation.HORIZONTAL, spacing=6, css="di-right")
        if status:
            dot = Gtk.Box()
            dot.add_css_class("status-dot")
            dot.add_css_class(status)
            right.append(dot)
        right.append(self._label(right_text))
        row.append(right)

        btn.set_child(row)
        return btn

    def _drawer_row(self, glyph, name, subtitle, control_widget):
        control_widget.set_tooltip_text(name)
        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=10, css="drawer-row")
        icon = self._label(glyph, "di-icon", xalign=0.5)
        self._center_icon(icon)
        icon.set_width_chars(2)
        icon.set_valign(Gtk.Align.CENTER)
        row.append(icon)
        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        copy.append(self._label(name, "di-name"))
        if subtitle:
            copy.append(self._label(subtitle, "di-sub"))
        row.append(copy)
        row.append(control_widget)
        return row

    def _drawer_select(self, label):
        btn = Gtk.Button()
        btn.add_css_class("drawer-select")
        inner = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
        inner.append(self._label(label))
        inner.append(self._label(G["chevron_right"]))
        btn.set_child(inner)
        return btn

    def _ghost_btn(self, label):
        btn = Gtk.Button(label=label)
        btn.add_css_class("ghost-btn")
        return btn

    def _icon_btn(self, glyph, danger=False):
        btn = Gtk.Button(label=glyph)
        name = {G["volume"]: "Mute audio", G["mic"]: "Mute microphone"}.get(glyph, "Control")
        btn.set_tooltip_text(name)
        self._name_control(btn, name)
        btn.add_css_class("icon-btn")
        if danger:
            btn.add_css_class("danger")
        return btn

    def _detail_header(self, title, meta=None, right_widget=None):
        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=8, css="panel-header")
        back = Gtk.Button(label=G["chevron_left"])
        back.add_css_class("back-btn")
        back.set_tooltip_text("Back")
        self._name_control(back, "Back")
        back.connect("clicked", lambda _b: self.go_back())
        row.append(back)
        row.append(self._label(title, ["panel-title", "with-back"]))
        row.append(Gtk.Box(hexpand=True))
        if right_widget is not None:
            right_widget.set_tooltip_text(title)
            row.append(right_widget)
        elif meta:
            row.append(self._label(meta, "panel-meta", xalign=1))
        return row

    def _hero_card_ref(self):
        """Hero card with ref-able sub-widgets. Populate via the returned NS."""
        card = self._box(Gtk.Orientation.HORIZONTAL, spacing=14, css="hero-card")
        icon = self._label("", "hero-icon-wrap", xalign=0.5)
        self._center_icon(icon)
        icon.set_width_chars(3)
        icon.set_halign(Gtk.Align.CENTER)
        icon.set_valign(Gtk.Align.CENTER)
        card.append(icon)
        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        title = self._label("", "hero-title")
        sub = self._label("", "hero-sub")
        copy.append(title)
        copy.append(sub)
        card.append(copy)
        meta_box = self._box(Gtk.Orientation.VERTICAL, css="hero-meta")
        big = self._label("", "hero-big", xalign=1)
        small = self._label("", "hero-small", xalign=1)
        meta_box.append(big)
        meta_box.append(small)
        card.append(meta_box)
        return SimpleNamespace(
            widget=card, icon=icon, title=title, sub=sub, big=big, small=small,
        )

    def _fill_stat_grid(self, bar, cells):
        """Clear and re-populate a stat strip Grid with (value, label) cells."""
        self._clear(bar)
        for i, (value, label) in enumerate(cells):
            cell = self._box(Gtk.Orientation.VERTICAL, css="vpn-stat-cell")
            cell.append(self._label(value, "vpn-stat-value", xalign=0.5))
            cell.append(self._label(label, "vpn-stat-label", xalign=0.5))
            bar.attach(cell, i, 0, 1, 1)
