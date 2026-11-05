#!/usr/bin/env python3
"""Minimal pill-style app launcher for Hyprland."""

import ctypes, os

os.environ['GDK_BACKEND'] = 'wayland'

# GObject introspection loads shared libraries lazily: libgtk4-layer-shell.so
# would normally be dlopen'd only when init_for_window() is first called —
# by which point GTK has already opened the Wayland display and the
# compositor's zwlr_layer_shell_v1 global has been missed.  Loading the
# library explicitly here, before any GTK import, ensures its GDK hooks
# are registered in time.
_gls = os.environ.get('GTK4_LAYER_SHELL_LIB', '')
if _gls:
    ctypes.CDLL(_gls, mode=ctypes.RTLD_GLOBAL)

import gi
gi.require_version('Gtk4LayerShell', '1.0')
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk4LayerShell, Gtk, Gdk, GLib, Pango

import fcntl, hashlib, json, re, shlex, subprocess, sys, threading
from pathlib import Path

def is_waybar_visible(timeout=1):
    try:
        result = subprocess.run(
            ['hyprctl', '-j', 'layers'],
            capture_output=True, text=True, timeout=timeout,
        )
        data = json.loads(result.stdout)
        for monitor_data in data.values():
            # Level 2 = "top" layer. When hidden via SIGUSR1, waybar drops to level 1.
            for s in monitor_data.get('levels', {}).get('2', []):
                if s.get('namespace') == 'waybar':
                    return True
        return False
    except Exception:
        return False

_session = hashlib.sha256(os.environ.get('WAYLAND_DISPLAY', 'default').encode()).hexdigest()[:12]
LOCK_PATH = Path(os.environ.get('XDG_RUNTIME_DIR', f'/tmp/launcher-{os.getuid()}')) / f'launcher-{_session}.lock'
_lock_fd = None

def acquire_lock():
    global _lock_fd
    try:
        LOCK_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        _lock_fd = open(LOCK_PATH, 'w')
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except (IOError, OSError):
        return False

def scan_path():
    apps = set()
    for d in os.environ.get('PATH', '').split(':'):
        try:
            for name in os.listdir(d):
                p = os.path.join(d, name)
                if os.path.isfile(p) and os.access(p, os.X_OK):
                    apps.add(name)
        except OSError:
            pass
    return sorted(apps)

APPS = scan_path()

def best_match(query):
    if not query:
        return ''
    q = query.lower()
    for app in APPS:
        if app.lower().startswith(q) and app.lower() != q:
            return app[len(q):]
    return ''

DEFAULTS = {'bg': '161a20', 'orange': '4a5568', 'amber': '8aa4b8', 'text': 'c8d0d8'}

def load_colors():
    c = dict(DEFAULTS)
    try:
        with open(os.path.expanduser('~/.config/waybar/colors.css')) as f:
            for line in f:
                m = re.match(r'@define-color\s+(\w+)\s+#([0-9a-fA-F]{6})', line)
                if m:
                    c[m.group(1)] = m.group(2)
    except OSError:
        pass
    return c

def h2rgb(h):
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))


class Launcher(Gtk.Application):
    def __init__(self, colors):
        super().__init__(application_id='io.personal.launcher')
        self.colors = colors
        self.typed = ''
        self._win = None
        self._waybar_state = None
        self._waybar_gathering = False
        self._waybar_poll_id = 0
        self.connect('activate', self._build)
        self.connect('shutdown', self._on_shutdown)

    def _build(self, _):
        win = Gtk.ApplicationWindow(application=self)
        win.set_decorated(False)
        win.set_resizable(False)
        win.set_title('Launcher')

        Gtk4LayerShell.init_for_window(win)
        Gtk4LayerShell.set_layer(win, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.TOP,    True)
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.LEFT,   False)
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.RIGHT,  False)
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.BOTTOM, False)
        Gtk4LayerShell.set_exclusive_zone(win, -1)

        Gtk4LayerShell.set_keyboard_mode(win, Gtk4LayerShell.KeyboardMode.EXCLUSIVE)
        Gtk4LayerShell.set_namespace(win, 'launcher')

        self._win = win
        self._waybar_state = is_waybar_visible(timeout=0.1)
        self._apply_position()
        self._waybar_poll_id = GLib.timeout_add(1000, self._poll_waybar)

        provider = Gtk.CssProvider()
        provider.load_from_data(self._css().encode())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        self.entry = Gtk.Entry()
        self.entry.set_name('entry')
        self.entry.set_width_chars(20)
        self.entry.set_alignment(0.5)
        self.entry.set_placeholder_text('Run a command…')
        self.entry.set_enable_undo(True)
        self.entry.update_property([Gtk.AccessibleProperty.LABEL], ['Command'])
        self.entry.set_tooltip_text('Enter runs the typed command. Tab accepts completion.')
        self.entry.connect('changed', self._on_changed)

        pill = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        pill.set_name('pill')
        pill.append(self.entry)
        self.hint = Gtk.Label(xalign=0.5)
        self.hint.set_name('launcher-hint')
        self.hint.set_ellipsize(Pango.EllipsizeMode.END)
        self.hint.set_max_width_chars(36)
        self.hint.set_visible(False)
        pill.append(self.hint)
        self.error_label = Gtk.Label(xalign=0.5)
        self.error_label.set_name('launcher-error')
        self.error_label.set_wrap(True)
        self.error_label.set_max_width_chars(32)
        self.error_label.set_visible(False)
        pill.append(self.error_label)

        win.set_child(pill)

        kc = Gtk.EventControllerKey()
        kc.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        kc.connect('key-pressed', self._on_key)
        win.add_controller(kc)

        win.present()
        self.entry.grab_focus()

    def _apply_position(self):
        # waybar: margin-top=6, height=38 → 44px footprint; add 8px gap = 52px
        top_margin = 52 if self._waybar_state else 6
        Gtk4LayerShell.set_margin(self._win, Gtk4LayerShell.Edge.TOP, top_margin)

    def _poll_waybar(self):
        if not self._waybar_gathering:
            self._waybar_gathering = True
            def gather():
                current = is_waybar_visible()
                GLib.idle_add(self._apply_waybar, current)
            threading.Thread(target=gather, daemon=True).start()
        return GLib.SOURCE_CONTINUE

    def _apply_waybar(self, current):
        self._waybar_gathering = False
        if current != self._waybar_state:
            self._waybar_state = current
            self._apply_position()
        return False

    def _on_shutdown(self, *_args):
        if self._waybar_poll_id:
            GLib.source_remove(self._waybar_poll_id)
            self._waybar_poll_id = 0

    def _css(self):
        c = self.colors
        bg = h2rgb(c['bg'])
        or_ = h2rgb(c['orange'])
        am = h2rgb(c['amber'])
        tx = h2rgb(c['text'])
        settings = Gtk.Settings.get_default()
        opening = 'launcher-open 120ms cubic-bezier(0.16, 1, 0.3, 1) both'
        if settings is not None and not settings.get_property('gtk-enable-animations'):
            opening = 'none'
        # Pill dimensions mirror the waybar clock pill exactly:
        #   bar height=48, margin-top=6 on bar, pill margin=6px top/bottom
        #   → pill height = 48 - 6 - 6 = 36px, same font/weight as clock
        return f"""
        @keyframes launcher-open {{
            from {{ opacity: 0; transform: scale(0.88); }}
            to   {{ opacity: 1; transform: scale(1.0);  }}
        }}
        window {{
            background: none;
            border: none;
            box-shadow: none;
        }}
        #pill {{
            background: rgba({bg[0]},{bg[1]},{bg[2]},0.92);
            border-radius: 12px;
            border: 1px solid rgba({or_[0]},{or_[1]},{or_[2]},0.25);
            margin: 6px 3px;
            animation: {opening};
        }}
        #entry, #entry > text {{
            background: transparent;
            color: rgba({tx[0]},{tx[1]},{tx[2]},1.0);
            caret-color: rgba({tx[0]},{tx[1]},{tx[2]},1.0);
            border: none;
            box-shadow: none;
            outline: none;
            outline-width: 0px;
            font-size: 13px;
            font-weight: 500;
            padding: 0 18px;
            min-height: 36px;
        }}
        entry:focus, entry:focus-visible, entry:focus > text {{
            outline: none;
            outline-width: 0px;
            box-shadow: none;
            border: none;
        }}
        entry placeholder {{
            color: rgba({tx[0]},{tx[1]},{tx[2]},0.38);
        }}
        #entry selection, #entry > text selection {{
            background: rgba({am[0]},{am[1]},{am[2]},0.28);
            color: rgba({tx[0]},{tx[1]},{tx[2]},1.0);
        }}
        #launcher-hint, #launcher-error {{
            font-size: 11px;
            color: rgba({tx[0]},{tx[1]},{tx[2]},0.7);
            margin: 0 18px 8px;
        }}
        """

    def _on_changed(self, entry):
        self.typed = entry.get_text()
        self.error_label.set_visible(False)
        self._refresh()

    def _refresh(self):
        ghost = best_match(self.typed)
        self.hint.set_text('Tab: ' + self.typed + ghost if ghost else '')
        self.hint.set_visible(bool(ghost))

    def _set_error(self, text):
        self.error_label.set_text(text)
        self.error_label.set_visible(True)
        self.entry.grab_focus()

    def _launch(self):
        cmd = self.typed.strip()
        if not cmd:
            return
        try:
            subprocess.Popen(
                shlex.split(cmd),
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, ValueError) as exc:
            print(f"Could not launch {cmd!r}: {exc}", file=sys.stderr)
            self._set_error('Could not start command. Check its name or arguments.')
            return
        self.quit()

    def _on_key(self, _ctrl, keyval, _code, _mods):
        if keyval == Gdk.KEY_Escape:
            self.quit()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self._launch()
            return True
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_Right):
            if _mods & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK):
                return False
            if self.entry.get_position() != len(self.typed) or self.entry.get_property('selection-bound') != self.entry.get_position():
                return False
            ghost = best_match(self.typed)
            if ghost:
                self.entry.set_text(self.typed + ghost)
                self.entry.set_position(-1)
                return True
        return False


if __name__ == '__main__':
    if not acquire_lock():
        sys.exit(0)
    GLib.set_application_name('Launcher')
    GLib.set_prgname('launcher')
    app = Launcher(load_colors())
    sys.exit(app.run(None))
