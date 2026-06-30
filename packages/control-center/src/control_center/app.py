"""Control Center GTK application.

Holds the lifecycle (window, tick loops, navigation), the reusable widget
primitives (label/box/tile/chip/slider/drawer/...), and the pending-write
override machinery. View-specific build methods live in ``views/*`` mixins
and are mixed in here.
"""

import os
import signal
import threading
import time
from types import SimpleNamespace

from gi.repository import Gdk, GLib, Gtk, Gtk4LayerShell, Pango

from .constants import (
    BATTERY_LEVELS,
    FAST_STATE_KEYS,
    G,
    PANEL_CONTENT_WIDTH,
    PANEL_MARGIN,
    PANEL_TOTAL_WIDTH,
    SLOW_STATE_KEYS,
    VIEWS,
)
from .css import build_css
from .gather import gather_fast_state, gather_slow_state
from .state_file import clear_state, read_state, write_state
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
        self._refreshers = []
        self._fast_poll_id = 0
        self._slow_poll_id = 0
        self._theme_reload_signal_id = 0
        self._fast_gathering = False
        self._slow_gathering = False
        # Optimistic overrides while slow writes (e.g. tailscale up) catch up.
        # key -> (target_value, expires_at)
        self._pending = {}
        self.connect("activate", self._build)
        self.connect("shutdown", self._on_shutdown)

    # ── Window + stack ────────────────────────────────────────

    def _build(self, _app):
        self._install_css_provider()

        self.win = Gtk.ApplicationWindow(application=self)
        self.win.set_decorated(False)
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
        self.stack.set_transition_duration(260)
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

        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        panel.set_name("panel")
        panel.set_size_request(PANEL_TOTAL_WIDTH, -1)
        panel.set_halign(Gtk.Align.END)
        panel.set_valign(Gtk.Align.START)
        panel.set_margin_top(PANEL_MARGIN)
        panel.set_margin_end(PANEL_MARGIN)
        panel.append(self.stack)

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
            GLib.timeout_add(250, self._arm_dismiss)
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

    def _arm_dismiss(self):
        self._dismiss_armed = True
        return False  # one-shot

    def _on_shutdown(self, *_args):
        if self._fast_poll_id:
            GLib.source_remove(self._fast_poll_id)
            self._fast_poll_id = 0
        if self._slow_poll_id:
            GLib.source_remove(self._slow_poll_id)
            self._slow_poll_id = 0
        if self._theme_reload_signal_id:
            GLib.source_remove(self._theme_reload_signal_id)
            self._theme_reload_signal_id = 0
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
        if self.win is None:
            return
        self._visible = True
        self._dismiss_armed = False
        self.win.present()
        GLib.timeout_add(250, self._arm_dismiss)
        self._write_presence()
        self._tick_fast()
        self._tick_slow()

    def _hide_window(self):
        if self.win is None:
            return
        self._visible = False
        self._dismiss_armed = False
        self.win.set_visible(False)
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
        def _worker():
            try:
                state = gather_fast_state(previous)
            except Exception:
                state = None
            GLib.idle_add(self._apply_fast_state, state)
        threading.Thread(target=_worker, daemon=True).start()
        return True

    def _tick_slow(self):
        if not self._visible:
            return True
        if self._slow_gathering:
            return True
        self._slow_gathering = True
        previous = self.state
        def _worker():
            try:
                state = gather_slow_state(previous)
            except Exception:
                state = None
            GLib.idle_add(self._apply_slow_state, state)
        threading.Thread(target=_worker, daemon=True).start()
        return True

    def _apply_fast_state(self, state):
        self._fast_gathering = False
        self._refresh_theme_css()
        return self._apply_state(state, FAST_STATE_KEYS)

    def _apply_slow_state(self, state):
        self._slow_gathering = False
        return self._apply_state(state, SLOW_STATE_KEYS)

    def _refresh_ui(self):
        for fn in self._refreshers:
            try:
                fn(self.state)
            except Exception:
                pass
        return False

    def _apply_state(self, state, keys=None):
        if state is None:
            return False
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
        self._css_provider.load_from_data(build_css(self.colors).encode())
        Gtk.StyleContext.add_provider_for_display(
            display,
            self._css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _refresh_theme_css(self, force=False):
        colors = load_colors()
        if not force and colors == self.colors:
            return
        self.colors = colors
        self._install_css_provider()

    @staticmethod
    def _set_class(widget, klass, on):
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

    # ── Pending overrides for slow writes ─────────────────────

    def _pending_set(self, key, target, ttl_s=None):
        self._pending[key] = (
            target, time.time() + (ttl_s or self.PENDING_TTL_S),
        )
        GLib.idle_add(self._refresh_ui)

    def effective(self, key, polled):
        """Return the user-intended value if a pending write is in flight
        and hasn't yet been observed in the polled state; otherwise polled."""
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

    def _bind_slider(self, slider, on_set):
        """Wire a slider SimpleNamespace to user input. on_set(pct) called
        on click/drag/scroll. Refresh ticks should call _set_slider_polled
        instead of _set_slider so they skip during active drags."""
        track = slider.fill.get_parent()
        track.set_can_target(True)
        slider._dragging = False
        slider._last_pct = -1

        def _on_track_width(*_):
            if slider._last_pct >= 0:
                self._set_slider(slider, slider._last_pct)
        track.connect("notify::width", _on_track_width)

        def pos_to_pct(x):
            w = track.get_width()
            if w <= 0:
                return None
            return max(0, min(100, round(x / w * 100)))

        last = {"t": 0.0}

        def fire(pct, force=False):
            if pct is None:
                return
            now = time.monotonic()
            if not force and pct == slider._last_pct and now - last["t"] < 0.08:
                return  # throttle drag-update spam
            last["t"] = now
            slider._last_pct = pct
            self._set_slider(slider, pct)
            on_set(pct)

        click = Gtk.GestureClick()

        def on_released(_g, _n, x, _y):
            fire(pos_to_pct(x), force=True)
        click.connect("released", on_released)
        track.add_controller(click)

        drag = Gtk.GestureDrag()
        ds = {"base_x": 0.0}

        def on_begin(_g, sx, _sy):
            slider._dragging = True
            ds["base_x"] = sx
            fire(pos_to_pct(sx), force=True)

        def on_update(_g, ox, _oy):
            fire(pos_to_pct(ds["base_x"] + ox))

        def on_end(_g, ox, _oy):
            fire(pos_to_pct(ds["base_x"] + ox), force=True)

            def _release(_sl=slider):
                _sl._dragging = False
                return False
            GLib.timeout_add(200, _release)
        drag.connect("drag-begin", on_begin)
        drag.connect("drag-update", on_update)
        drag.connect("drag-end", on_end)
        track.add_controller(drag)

        scroll = Gtk.EventControllerScroll.new(
            Gtk.EventControllerScrollFlags.VERTICAL,
        )

        def on_scroll(_c, _dx, dy):
            cur = slider._last_pct
            if cur < 0:
                try:
                    cur = int(slider.value.get_label() or "0")
                except ValueError:
                    cur = 0
            step = 5
            # Negative dy = wheel up = increase
            new = max(0, min(100, cur - int(dy) * step))
            fire(new, force=True)
            return True
        scroll.connect("scroll", on_scroll)
        slider.widget.add_controller(scroll)

    def _set_slider_polled(self, slider, pct):
        """Variant of _set_slider that skips when user is dragging."""
        if getattr(slider, "_dragging", False):
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
        """Visual switch. Toggle .on class via _set_class()."""
        sw = Gtk.Button()
        sw.add_css_class("switch")
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                sw.add_css_class(c)
        knob = Gtk.Box()
        knob.add_css_class("switch-knob")
        sw.set_child(knob)
        return sw

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
        """Build a slider row. Returns SimpleNamespace(widget, fill, value, aux)."""
        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=12, css="slider-row")
        row.set_size_request(376, -1)

        gbtn = Gtk.Button(label=glyph)
        gbtn.add_css_class("glyph-btn")
        row.append(gbtn)

        track = Gtk.Box()
        track.add_css_class("slider-track")
        track.set_hexpand(True)
        # No overflow:hidden here — it would clip the 16px knob down to the 8px
        # track height. The fill is rounded (border-radius) so it stays tidy
        # without clipping, and the knob is free to protrude as a real handle.
        fill = Gtk.Box()
        fill.add_css_class("slider-fill")
        fill.set_size_request(0, -1)
        # Pin the fill's own expand flag off: hexpand propagates UP from any
        # child, so the knob's hexpand below would otherwise make the fill
        # report as expandable and the track would stretch it to full width
        # (every knob pinned to the far right, ignoring the value). With an
        # explicit False the fill keeps its value-driven size_request width.
        fill.set_hexpand(False)
        knob = Gtk.Box()
        knob.add_css_class("slider-knob")
        # hexpand so the knob is allocated the fill's full content width;
        # halign=END then parks it at the fill's right edge (the value
        # position). Without hexpand the horizontal box packs this single child
        # at the start, leaving the knob at the left regardless of value.
        knob.set_hexpand(True)
        knob.set_halign(Gtk.Align.END)
        fill.append(knob)
        track.append(fill)
        row.append(track)

        val = self._label("0", "slider-value", xalign=1)
        val.set_width_chars(3)
        val.set_size_request(24, -1)
        row.append(val)

        aux = None
        aux_text = None
        if aux_label:
            aux = Gtk.Button()
            aux.add_css_class("slider-aux")
            aux.set_size_request(74, -1)
            aux_text = self._label(aux_label, "slider-aux-label", xalign=1)
            aux_text.set_ellipsize(Pango.EllipsizeMode.END)
            aux_text.set_max_width_chars(11)
            aux_text.set_size_request(74, -1)
            aux.set_child(aux_text)
            if aux_view:
                aux.connect("clicked", lambda _b, v=aux_view: self.go_to(v))
            row.append(aux)

        return SimpleNamespace(
            widget=row, glyph_btn=gbtn, fill=fill, value=val, aux=aux,
            aux_label=aux_text,
        )

    def _set_slider(self, slider, pct):
        pct = max(0, min(100, pct))
        track = slider.fill.get_parent()
        w = track.get_width()
        if w > 0:
            slider.fill.set_size_request(round(pct / 100 * w), -1)
        slider.value.set_label(str(int(pct)))

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
        btn.add_css_class("icon-btn")
        if danger:
            btn.add_css_class("danger")
        return btn

    def _detail_header(self, title, meta=None, right_widget=None):
        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=8, css="panel-header")
        back = Gtk.Button(label=G["chevron_left"])
        back.add_css_class("back-btn")
        back.connect("clicked", lambda _b: self.go_back())
        row.append(back)
        row.append(self._label(title, ["panel-title", "with-back"]))
        row.append(Gtk.Box(hexpand=True))
        if right_widget is not None:
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
