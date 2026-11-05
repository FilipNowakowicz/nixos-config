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
from gi.repository import Gtk4LayerShell, Gtk, Gdk, GLib, Gio, Pango

import argparse, fcntl, hashlib, json, re, shlex, subprocess, sys, threading, time, unicodedata
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


def search_text(value):
    return ''.join(c for c in unicodedata.normalize('NFKD', value.casefold())
                   if not unicodedata.combining(c))


def find_applications(apps, query, limit=6):
    query = search_text(query.strip())
    ranked = []
    for app in apps:
        name = search_text(app['name'])
        executable = search_text(app['executable'])
        keywords = search_text(' '.join(app['keywords']))
        if not query or name == query:
            score = 0
        elif executable == query:
            score = 1
        elif name.startswith(query):
            score = 2
        elif any(word.startswith(query) for word in name.split()):
            score = 3
        elif query in name:
            score = 4
        elif query in executable:
            score = 5
        elif query in keywords:
            score = 6
        elif all(word in ' '.join((name, executable, keywords)) for word in query.split()):
            score = 7
        else:
            continue
        ranked.append((score, app.get('order', 0), name, app['id'], app))
    return [item[4] for item in sorted(ranked, key=lambda item: item[:4])[:limit]]


def window_records(clients):
    records, seen = [], set()
    for window in clients:
        if not isinstance(window, dict):
            continue
        identity = window.get('stableId')
        if not window.get('mapped', True) or not isinstance(identity, str) or not re.fullmatch(r'[0-9a-fA-F]{1,32}', identity):
            continue
        if identity in seen:
            continue
        seen.add(identity)
        history = window.get('focusHistoryID', 99999)
        history = history if isinstance(history, int) and history > 0 else 100000
        app_class = str(window.get('class') or 'Application')
        workspace = window.get('workspace') or {}
        location = 'Workspace ' + str(workspace.get('name') or workspace.get('id') or '?')
        subtitle = app_class + ' · ' + location
        if window.get('focusHistoryID') == 0:
            subtitle += ' · Current'
        records.append({'id': identity, 'name': str(window.get('title') or app_class),
                        'executable': app_class, 'keywords': [location],
                        'subtitle': subtitle, 'order': history, 'info': None})
    return records


def hypr_target():
    signature = os.environ.get('HYPRLAND_INSTANCE_SIGNATURE', '')
    runtime = os.environ.get('XDG_RUNTIME_DIR', '')
    if not re.fullmatch(r'[A-Za-z0-9_]+', signature) or not Path(runtime).is_absolute():
        raise OSError('No explicit compositor session')
    if not (Path(runtime) / 'hypr' / signature / '.socket.sock').is_socket():
        raise OSError('Compositor session is unavailable')
    return signature, runtime


def hypr_query(arguments, target):
    if hypr_target() != target:
        raise OSError('Compositor session changed')
    signature, runtime = target
    env = {**os.environ, 'XDG_RUNTIME_DIR': runtime, 'HYPRLAND_INSTANCE_SIGNATURE': signature}
    result = subprocess.run(['hyprctl', '-i', signature, *arguments], env=env,
                            capture_output=True, text=True, timeout=1, check=False)
    if result.returncode:
        raise RuntimeError(result.stdout or result.stderr or 'Compositor request failed')
    return result.stdout


def contains_launcher_layer(value):
    if isinstance(value, dict):
        return value.get('namespace') == 'launcher' or any(contains_launcher_layer(child) for child in value.values())
    if isinstance(value, list):
        return any(contains_launcher_layer(child) for child in value)
    return False


def switch_window(identity, target):
    if not re.fullmatch(r'[0-9a-fA-F]{1,32}', identity):
        return 'unavailable'
    script = ('local target; for _, w in ipairs(hl.get_windows()) do '
              + 'if w.stable_id == "' + identity + '" then target = w; break end end; '
              + 'assert(target, "window closed"); hl.dispatch(hl.dsp.focus({window=target}))')
    try:
        # The Wayland unmap and IPC use separate sockets. Observe release before
        # focusing so their arrival order cannot leave an exclusive grab in place.
        release_deadline = time.monotonic() + 1
        while contains_launcher_layer(json.loads(hypr_query(['-j', 'layers'], target))):
            if time.monotonic() >= release_deadline:
                return 'unknown'
            time.sleep(0.02)
        if hypr_query(['eval', script], target).strip() != 'ok':
            return 'unknown'
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            active = json.loads(hypr_query(['-j', 'activewindow'], target))
            if isinstance(active, dict) and active.get('stableId') == identity:
                return 'confirmed'
            time.sleep(0.05)
    except RuntimeError as error:
        return 'closed' if 'window closed' in str(error) else 'unknown'
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 'unavailable'
    return 'unknown'

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
    def __init__(self, colors, mode='command'):
        super().__init__(application_id='io.personal.launcher')
        self.colors = colors
        self.typed = ''
        self.mode = mode
        self._applications = []
        self._index_ready = False
        self._index_error = False
        self._result_query = None
        self._window_gathering = False
        self._window_poll_id = 0
        self._switching = False
        self._closing = False
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
        placeholder = {'apps': 'Search apps, or > command…', 'windows': 'Find a window, or > command…'}.get(self.mode, 'Run a command…')
        self.entry.set_placeholder_text(placeholder)
        self.entry.set_enable_undo(True)
        name = {'apps': 'Application search', 'windows': 'Window search'}.get(self.mode, 'Command')
        self.entry.update_property([Gtk.AccessibleProperty.LABEL], [name])
        self.entry.set_tooltip_text('Enter runs the typed command. Tab accepts completion.' if self.mode == 'command'
                                    else 'Type to filter. Arrow keys choose; Enter activates. Use > for commands.')
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
        self.results = Gtk.ListBox()
        self.results.set_name('launcher-results')
        self.results.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.results.set_activate_on_single_click(True)
        self.results.connect('row-activated', lambda _list, row: self._activate_result(row))
        self.results.set_visible(False)
        self._results_scroller = Gtk.ScrolledWindow()
        self._results_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self._results_scroller.set_propagate_natural_height(True)
        self._results_scroller.set_min_content_height(1)
        self._results_scroller.set_child(self.results)
        self._results_scroller.set_visible(False)
        pill.append(self._results_scroller)
        if self.mode != 'command':
            monitors = win.get_display().get_monitors()
            width = monitors.get_item(0).get_geometry().width if monitors.get_n_items() else 1280
            height = monitors.get_item(0).get_geometry().height if monitors.get_n_items() else 720
            pill.set_size_request(min(420, max(280, width - 32)), -1)
            self._results_scroller.set_max_content_height(max(100, min(400, height - 180)))

        win.set_child(pill)

        kc = Gtk.EventControllerKey()
        kc.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        kc.connect('key-pressed', self._on_key)
        win.add_controller(kc)

        win.present()
        self.entry.grab_focus()
        if self.mode == 'apps':
            self._refresh()
            threading.Thread(target=self._gather_applications, daemon=True).start()
        elif self.mode == 'windows':
            self._refresh()
            self._poll_windows()
            self._window_poll_id = GLib.timeout_add(1000, self._poll_windows)

    def _poll_windows(self):
        if self._window_gathering or self._switching or self._closing:
            return True
        self._window_gathering = True
        def gather():
            try:
                target = hypr_target()
                clients = json.loads(hypr_query(['-j', 'clients'], target))
                if not isinstance(clients, list):
                    raise ValueError('Invalid window list')
                records = window_records(clients)
                if any(w.get('mapped', True) for w in clients if isinstance(w, dict)) and not records:
                    raise ValueError('Stable window identities are unavailable')
                for record in records:
                    record['target'] = target
                failed = False
            except (OSError, RuntimeError, ValueError, TypeError, subprocess.TimeoutExpired):
                records, failed = [], True
            GLib.idle_add(self._apply_windows, records, failed)
        threading.Thread(target=gather, daemon=True).start()
        return True

    def _apply_windows(self, records, failed):
        self._window_gathering = False
        if self._closing or self._switching:
            return False
        if records == self._applications and self._index_ready and failed == self._index_error:
            return False
        return self._apply_applications(records, failed)

    def _gather_applications(self):
        apps, seen, failed = [], set(), False
        try:
            for info in Gio.AppInfo.get_all():
                identity = info.get_id()
                if not identity or identity in seen or not info.should_show():
                    continue
                seen.add(identity)
                apps.append({'id': identity, 'name': info.get_display_name() or info.get_name() or identity,
                             'executable': os.path.basename(info.get_executable() or ''),
                             'keywords': list(info.get_keywords() or []) if hasattr(info, 'get_keywords') else [],
                             'info': info})
        except Exception:
            failed = True
        GLib.idle_add(self._apply_applications, apps, failed)

    def _apply_applications(self, apps, failed):
        self._applications = apps
        self._index_ready = True
        self._index_error = failed
        self._refresh()
        return False

    def _app_search(self):
        return self.mode != 'command' and not self.typed.lstrip().startswith('>')

    def _refresh_applications(self):
        previous = self.results.get_selected_row()
        same_query = self._result_query == self.typed
        previous_id = previous.record['id'] if previous is not None and same_query else None
        previous_index = previous.get_index() if previous is not None and same_query else 0
        focus = self._win.get_focus()
        restore_focus = focus is not None and (focus == self.results or focus.is_ancestor(self.results))
        if self._result_query != self.typed:
            self._results_scroller.get_vadjustment().set_value(0)
        self._result_query = self.typed
        child = self.results.get_first_child()
        while child is not None:
            next_child = child.get_next_sibling()
            self.results.remove(child)
            child = next_child
        matches = find_applications(self._applications, self.typed,
                                    limit=len(self._applications) if self.mode == 'windows' else 6)
        for record in matches:
            row = Gtk.ListBoxRow()
            row.record = record
            row.add_css_class('launcher-result')
            content = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            icon = record['info'].get_icon() if record['info'] is not None else None
            image = Gtk.Image.new_from_gicon(icon) if icon is not None else Gtk.Image.new_from_icon_name('application-x-executable')
            image.set_pixel_size(24)
            content.append(image)
            labels = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            label = Gtk.Label(label=record['name'], xalign=0)
            label.set_ellipsize(Pango.EllipsizeMode.END)
            label.set_hexpand(True)
            labels.append(label)
            if record.get('subtitle'):
                subtitle = Gtk.Label(label=record['subtitle'], xalign=0)
                subtitle.add_css_class('launcher-subtitle')
                subtitle.set_ellipsize(Pango.EllipsizeMode.END)
                labels.append(subtitle)
            labels.set_hexpand(True)
            content.append(labels)
            row.set_child(content)
            self.results.append(row)
            if record['id'] == previous_id:
                self.results.select_row(row)
        if self.results.get_selected_row() is None:
            self.results.select_row(self.results.get_row_at_index(max(0, min(previous_index, len(matches) - 1))))
        self.results.set_visible(bool(matches))
        self._results_scroller.set_visible(bool(matches))
        if restore_focus:
            selected = self.results.get_selected_row()
            (selected if selected is not None else self.entry).grab_focus()
        noun = 'windows' if self.mode == 'windows' else 'applications'
        if not self._index_ready:
            text = 'Loading ' + noun + '…'
        elif self._index_error:
            text = noun.capitalize() + ' unavailable. Use > to run a command.'
        elif not matches:
            text = 'No matching ' + noun + '. Use > to run a command.'
        else:
            text = '↑ ↓ to choose · Enter to ' + ('switch' if self.mode == 'windows' else 'open')
        self.hint.set_text(text)
        self.hint.set_visible(True)

    def _activate_result(self, row=None):
        row = row or self.results.get_selected_row()
        if row is None:
            return
        if self.mode == 'windows':
            if self._switching:
                return
            self._switching = True
            self.entry.set_sensitive(False)
            self.results.set_sensitive(False)
            self.error_label.set_visible(False)
            self.hint.set_text('Switching window…')
            # An exclusive layer surface prevents Hyprland from focusing the
            # selected window. Release it before dispatch, then verify focus.
            self._win.set_visible(False)
            identity, target = row.record['id'], row.record['target']
            def focus():
                outcome = switch_window(identity, target)
                GLib.idle_add(self._window_focused, outcome)
            threading.Thread(target=focus, daemon=True).start()
            return
        try:
            context = Gdk.Display.get_default().get_app_launch_context()
            if not row.record['info'].launch([], context):
                raise OSError('Application launch was rejected')
        except (GLib.Error, OSError):
            self._set_error('Could not open application. Try again.')
            return
        self.quit()

    def _window_focused(self, outcome):
        if self._closing:
            return False
        self._switching = False
        self.entry.set_sensitive(True)
        self.results.set_sensitive(True)
        if outcome == 'confirmed':
            self.quit()
        else:
            self._win.present()
            self._set_error('That window closed. Choose another.' if outcome == 'closed'
                            else 'Could not confirm the window switch. Try again.')
            self._poll_windows()
        return False

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
        self._closing = True
        if self._window_poll_id:
            GLib.source_remove(self._window_poll_id)
            self._window_poll_id = 0
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
        #launcher-results {{ background: transparent; margin: 0 8px 8px; }}
        .launcher-result {{ padding: 8px; border-radius: 7px; }}
        .launcher-result:selected {{ background: rgba({am[0]},{am[1]},{am[2]},0.18); }}
        .launcher-result label {{ color: rgba({tx[0]},{tx[1]},{tx[2]},1); font-size: 13px; }}
        .launcher-result .launcher-subtitle {{ color: rgba({tx[0]},{tx[1]},{tx[2]},0.6); font-size: 11px; }}
        """

    def _on_changed(self, entry):
        self.typed = entry.get_text()
        self.error_label.set_visible(False)
        self._refresh()

    def _refresh(self):
        if self._app_search():
            self._refresh_applications()
            return
        self.results.set_visible(False)
        self._results_scroller.set_visible(False)
        query = self.typed.lstrip()[1:].lstrip() if self.mode != 'command' else self.typed
        ghost = best_match(query)
        self.hint.set_text('Tab: ' + query + ghost if ghost else '')
        self.hint.set_visible(bool(ghost))

    def _set_error(self, text):
        self.error_label.set_text(text)
        self.error_label.set_visible(True)
        self.entry.grab_focus()

    def _launch(self):
        cmd = self.typed.strip()
        if self.mode != 'command':
            cmd = cmd[1:].lstrip()
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
            self._activate_result() if self._app_search() else self._launch()
            return True
        if self._app_search() and keyval in (Gdk.KEY_Up, Gdk.KEY_Down):
            row = self.results.get_selected_row()
            index = row.get_index() if row is not None else -1
            next_index = index + (1 if keyval == Gdk.KEY_Down else -1)
            target = self.results.get_row_at_index(max(0, next_index))
            if target is not None:
                self.results.select_row(target)
                ok, bounds = target.compute_bounds(self.results)
                if ok:
                    adjustment = self._results_scroller.get_vadjustment()
                    top, bottom = bounds.origin.y, bounds.origin.y + bounds.size.height
                    if top < adjustment.get_value():
                        adjustment.set_value(top)
                    elif bottom > adjustment.get_value() + adjustment.get_page_size():
                        adjustment.set_value(bottom - adjustment.get_page_size())
            return True
        if self._app_search():
            return False
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_Right):
            if _mods & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK):
                return False
            if self.entry.get_position() != len(self.typed) or self.entry.get_property('selection-bound') != self.entry.get_position():
                return False
            query = self.typed.lstrip()[1:].lstrip() if self.mode != 'command' else self.typed
            ghost = best_match(query)
            if ghost:
                self.entry.set_text(self.typed + ghost)
                self.entry.set_position(-1)
                return True
        return False


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Minimal application search and command launcher')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--apps', action='store_true', help='search desktop applications; use > for a command')
    modes.add_argument('--windows', action='store_true', help='find and switch to a window in the current compositor session')
    args = parser.parse_args()
    if not acquire_lock():
        sys.exit(0)
    GLib.set_application_name('Launcher')
    GLib.set_prgname('launcher')
    app = Launcher(load_colors(), mode='windows' if args.windows else 'apps' if args.apps else 'command')
    sys.exit(app.run(None))
