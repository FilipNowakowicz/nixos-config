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

import fcntl, json, re, subprocess, sys

def is_waybar_visible():
    try:
        result = subprocess.run(
            ['hyprctl', '-j', 'layers'],
            capture_output=True, text=True, timeout=1,
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

LOCK_PATH = '/tmp/launcher.lock'
_lock_fd = None

def acquire_lock():
    global _lock_fd
    try:
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
        self.connect('activate', self._build)

    def _build(self, _):
        win = Gtk.ApplicationWindow(application=self)
        win.set_decorated(False)
        win.set_resizable(False)

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
        self._waybar_state = is_waybar_visible()
        self._apply_position()
        GLib.timeout_add(250, self._poll_waybar)

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

        pill = Gtk.Box()
        pill.set_name('pill')
        pill.append(self.entry)

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
        current = is_waybar_visible()
        if current != self._waybar_state:
            self._waybar_state = current
            self._apply_position()
        return GLib.SOURCE_CONTINUE

    def _css(self):
        c = self.colors
        bg = h2rgb(c['bg'])
        or_ = h2rgb(c['orange'])
        am = h2rgb(c['amber'])
        tx = h2rgb(c['text'])
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
            animation: launcher-open 120ms cubic-bezier(0.16, 1, 0.3, 1) both;
        }}
        #entry, #entry > text {{
            background: transparent;
            color: rgba({tx[0]},{tx[1]},{tx[2]},1.0);
            caret-color: rgba({am[0]},{am[1]},{am[2]},1.0);
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
        #entry selection, #entry > text selection {{
            background: transparent;
            color: rgba({tx[0]},{tx[1]},{tx[2]},1.0);
        }}
        """

    def _refresh(self):
        ghost = best_match(self.typed)
        full = self.typed + ghost
        self.entry.set_text(full)
        self.entry.set_position(len(self.typed))

        attrs = Pango.AttrList()
        if ghost:
            am = h2rgb(self.colors['amber'])
            bg = h2rgb(self.colors['bg'])
            gr = int(bg[0] + (am[0] - bg[0]) * 0.5)
            gg = int(bg[1] + (am[1] - bg[1]) * 0.5)
            gb = int(bg[2] + (am[2] - bg[2]) * 0.5)
            start = len(self.typed.encode('utf-8'))
            end   = len(full.encode('utf-8'))
            fg = Pango.attr_foreground_new(gr * 257, gg * 257, gb * 257)
            fg.start_index = start
            fg.end_index   = end
            attrs.insert(fg)
        self.entry.set_attributes(attrs)

    def _launch(self):
        ghost = best_match(self.typed)
        cmd = (self.typed + ghost).strip()
        if cmd:
            subprocess.Popen(
                cmd.split(),
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        self.quit()

    def _on_key(self, _ctrl, keyval, _code, _mods):
        if keyval == Gdk.KEY_Escape:
            self.quit()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self._launch()
            return True
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_Right):
            ghost = best_match(self.typed)
            if ghost:
                self.typed += ghost
                self._refresh()
            return True
        if keyval == Gdk.KEY_BackSpace:
            if self.typed:
                self.typed = self.typed[:-1]
                self._refresh()
            return True
        uchar = Gdk.keyval_to_unicode(keyval)
        if uchar and chr(uchar).isprintable():
            self.typed += chr(uchar)
            self._refresh()
            return True
        return False


if __name__ == '__main__':
    if not acquire_lock():
        sys.exit(0)
    app = Launcher(load_colors())
    sys.exit(app.run(None))
