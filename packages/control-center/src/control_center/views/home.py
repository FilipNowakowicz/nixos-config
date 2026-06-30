"""Home view: tile grid, sliders, power profile, now playing, footer.

Layout follows the L2 "seamless" redesign — borderless tiles and bare sliders
on one flat surface separated by hairline dividers, a 3×2 toggle grid, B2
sliders, the power segment, a bare media row, and a consolidated footer that
carries the battery readout plus the theme/lock/sleep/power actions.
"""

import os
from types import SimpleNamespace

from gi.repository import Gtk, Pango

from .. import actions
from ..actions import (
    act_keep_awake,
    act_lock,
    act_mpris,
    act_night_light,
    act_poweroff,
    act_set_brightness,
    act_set_power_profile,
    act_set_sink_volume,
    act_set_source_volume,
    act_suspend,
    act_switch_theme,
    act_toggle_sink_mute,
    act_toggle_source_mute,
)
from ..constants import G


class HomeViewMixin:
    def _build_home_view(self):
        caps = self.state.get("caps", {})
        brightness_available = caps.get("brightness", True)
        night_light_available = caps.get("night_light", True)
        dnd_available = caps.get("dnd", True)
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")

        # ── Header ──
        header = self._box(Gtk.Orientation.HORIZONTAL, css="panel-header")
        title = self._box(Gtk.Orientation.HORIZONTAL, spacing=8, css="panel-title")
        title.append(self._label(G["live_dot"], "live-dot"))
        title.append(self._label("Control Center"))
        header.append(title)
        header.append(Gtk.Box(hexpand=True))
        meta = self._label("", "panel-meta", xalign=1)
        header.append(meta)
        view.append(header)

        view.append(self._divider())

        # ── 3×2 toggle grid (borderless, circular icon badges) ──
        # Per-glyph vertical nudge (Pango baseline rise, in Pango units ≈ 1024
        # per px) — some Nerd Font icons are bottom/top-heavy so they don't sit
        # centred in the circular badge even with xalign/yalign 0.5. Persists
        # across set_label() since the attribute spans the whole run.
        def _rise(label, units):
            if not units:
                return

            def apply(*_a):
                attrs = Pango.AttrList()
                attrs.insert(Pango.attr_rise_new(units))
                label.set_attributes(attrs)
            apply()
            # Refresh re-sets these glyphs via set_label(), which drops the
            # attribute list — reapply the rise whenever the text changes.
            label.connect("notify::label", apply)

        def mk_tile(glyph, label, view_name=None, rise=0):
            btn = Gtk.Button()
            btn.add_css_class("gtile")
            inner = self._box(Gtk.Orientation.VERTICAL, spacing=6)
            inner.set_halign(Gtk.Align.CENTER)
            ic = self._center_icon(self._label(glyph, "gtile-ic", xalign=0.5))
            _rise(ic, rise)
            inner.append(ic)
            lbl = self._label(label, "gtile-l", xalign=0.5)
            sub = self._label("", "gtile-s", xalign=0.5)
            sub.set_ellipsize(Pango.EllipsizeMode.END)
            sub.set_max_width_chars(12)
            inner.append(lbl)
            inner.append(sub)
            btn.set_child(inner)
            if view_name:
                btn.connect("clicked", lambda _b, v=view_name: self.go_to(v))
            return SimpleNamespace(widget=btn, glyph=ic, title=lbl, sub=sub)

        wifi_t = mk_tile(G["wifi"], "Wi-Fi", view_name="wifi", rise=2600)
        bt_t = mk_tile(G["bluetooth"], "Bluetooth", view_name="bluetooth", rise=-900)
        vpn_t = mk_tile(G["shield"], "VPN", view_name="vpn")
        focus_t = mk_tile(G["bell_off"], "Focus", view_name="dnd")
        awake_t = mk_tile(G["coffee"], "Awake")
        night_t = mk_tile(G["moon"], "Night")
        night_t.widget.set_sensitive(night_light_available)

        grid = Gtk.Grid(
            column_homogeneous=True, column_spacing=7, row_spacing=4,
        )
        grid.add_css_class("tile-grid")
        for i, t in enumerate([wifi_t, bt_t, vpn_t]):
            grid.attach(t.widget, i, 0, 1, 1)
        for i, t in enumerate([focus_t, awake_t, night_t]):
            grid.attach(t.widget, i, 1, 1, 1)
        view.append(grid)

        def _on_awake(_b):
            want = not self.effective("keep_awake", self.state.get("keep_awake", False))
            self._pending_set("keep_awake", want, ttl_s=4)
            self._set_class(awake_t.widget, "on", want)
            awake_t.sub.set_label("On" if want else "Off")
            act_keep_awake(want)
        awake_t.widget.connect("clicked", _on_awake)

        def _on_night(_b):
            want = not self.effective("night_light", self.state.get("night_light", False))
            self._pending_set("night_light", want, ttl_s=4)
            self._set_class(night_t.widget, "on", want)
            night_t.sub.set_label("On" if want else "Off")
            act_night_light(want)
        night_t.widget.connect("clicked", _on_night)

        view.append(self._divider())

        # ── B2 sliders (bare) ──
        vol_s = self._slider_row(G["volume"])
        brt_s = self._slider_row(G["sun"])
        mic_s = self._slider_row(G["mic"])
        sliders = self._box(Gtk.Orientation.VERTICAL, spacing=12)
        sliders.append(vol_s.widget)
        sliders.append(brt_s.widget)
        sliders.append(mic_s.widget)
        view.append(sliders)

        self._bind_slider(vol_s, act_set_sink_volume)
        if brightness_available:
            self._bind_slider(brt_s, act_set_brightness)
        else:
            brt_s.widget.set_sensitive(False)
        self._bind_slider(mic_s, act_set_source_volume)

        def _on_mute_sink(_b):
            self._pending_set("audio.sink_muted",
                              not self.state["audio"]["sink_muted"], ttl_s=2)
            act_toggle_sink_mute()
        vol_s.glyph_btn.connect("clicked", _on_mute_sink)

        def _on_mute_source(_b):
            self._pending_set("audio.source_muted",
                              not self.state["audio"]["source_muted"], ttl_s=2)
            act_toggle_source_mute()
        mic_s.glyph_btn.connect("clicked", _on_mute_source)

        # Secondary-click the device icon to open its detail view (output/input
        # picker). The redesign dropped the old aux buttons that linked there, so
        # right-click restores the entry point without adding visual clutter;
        # left-click stays quick-mute.
        def _nav_secondary(widget, view_name):
            gesture = Gtk.GestureClick()
            gesture.set_button(3)  # right mouse button
            gesture.connect("pressed", lambda *_a, v=view_name: self.go_to(v))
            widget.add_controller(gesture)
        _nav_secondary(vol_s.glyph_btn, "volume")
        _nav_secondary(mic_s.glyph_btn, "microphone")

        view.append(self._divider())

        # ── Power profile ──
        pp = self._segmented(
            [(G["leaf"], "Saver"), (G["gauge"], "Balanced"),
             (G["zap"], "Perf")],
        )
        view.append(pp.widget)
        pp_keys = ["power-saver", "balanced", "performance"]
        for key, btn in zip(pp_keys, pp.buttons):
            def _on_pp(_b, k=key):
                self._pending_set("power_profile", k, ttl_s=3)
                for kk, bb in zip(pp_keys, pp.buttons):
                    self._set_class(bb, "active", kk == k)
                act_set_power_profile(k)
            btn.connect("clicked", _on_pp)

        view.append(self._divider())

        # ── Now playing (bare media row) ──
        def media_btn(glyph, primary=False):
            b = Gtk.Button(label=glyph)
            b.add_css_class("media-btn")
            if primary:
                b.add_css_class("primary")
            return b

        np = self._box(Gtk.Orientation.HORIZONTAL, spacing=11, css="nowplaying")
        art_fallback = Gtk.Box()
        art_fallback.add_css_class("album-art")
        art_note = self._center_icon(self._label(G["music"], "album-art-note", xalign=0.5))
        art_note.set_hexpand(True)
        art_fallback.append(art_note)
        art_pic = Gtk.Picture()
        art_pic.add_css_class("album-art-pic")
        art_pic.set_content_fit(Gtk.ContentFit.COVER)
        art_pic.set_visible(False)
        art_overlay = Gtk.Overlay()
        art_overlay.set_size_request(38, 38)
        art_overlay.set_child(art_fallback)
        art_overlay.add_overlay(art_pic)
        np.append(art_overlay)
        track = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        track.set_hexpand(True)
        track.set_valign(Gtk.Align.CENTER)
        np_title = self._label("", "np-title")
        np_title.set_ellipsize(Pango.EllipsizeMode.END)
        np_title.set_xalign(0)
        np_artist = self._label("", "np-artist")
        np_artist.set_ellipsize(Pango.EllipsizeMode.END)
        np_artist.set_xalign(0)
        track.append(np_title)
        track.append(np_artist)
        np.append(track)
        ctrl = self._box(Gtk.Orientation.HORIZONTAL, spacing=2)
        ctrl.set_valign(Gtk.Align.CENTER)
        skip_back_btn = media_btn(G["skip_back"])
        play_btn = media_btn(G["play"], primary=True)
        skip_fwd_btn = media_btn(G["skip_forward"])
        ctrl.append(skip_back_btn)
        ctrl.append(play_btn)
        ctrl.append(skip_fwd_btn)
        np.append(ctrl)
        view.append(np)

        skip_back_btn.connect(
            "clicked",
            lambda _b: act_mpris(self.state["now_playing"]["player"], "Previous"),
        )
        play_btn.connect(
            "clicked",
            lambda _b: act_mpris(self.state["now_playing"]["player"], "PlayPause"),
        )
        skip_fwd_btn.connect(
            "clicked",
            lambda _b: act_mpris(self.state["now_playing"]["player"], "Next"),
        )

        view.append(self._divider())

        # ── Footer (battery readout + power actions) ──
        def foot_btn(glyph, danger=False):
            b = Gtk.Button(label=glyph)
            b.add_css_class("foot-btn")
            if danger:
                b.add_css_class("danger")
            return b

        foot = self._box(Gtk.Orientation.HORIZONTAL, spacing=10, css="foot")
        bat_left = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
        bat_glyph = self._label("", "foot-bat-glyph")
        bat_pct = self._label("", "foot-bat")
        bat_meta = self._label("", "foot-bat-meta")
        bat_left.append(bat_glyph)
        bat_left.append(bat_pct)
        bat_left.append(bat_meta)
        foot.append(bat_left)
        foot.append(Gtk.Box(hexpand=True))
        fbtns = self._box(Gtk.Orientation.HORIZONTAL, spacing=4)
        theme_btn = foot_btn(G["palette"])
        lock_btn = foot_btn(G["lock"])
        sleep_btn = foot_btn(G["sleep"])
        power_btn = foot_btn(G["power"], danger=True)
        for b in (theme_btn, lock_btn, sleep_btn, power_btn):
            fbtns.append(b)
        foot.append(fbtns)
        view.append(foot)

        lock_btn.connect("clicked", lambda _b: (act_lock(), self.quit()))
        sleep_btn.connect("clicked", lambda _b: (self.quit(), act_suspend()))
        power_btn.connect("clicked", lambda _b: (self.quit(), act_poweroff()))

        # ── Theme picker (revealed from the footer theme button) ──
        revealer = Gtk.Revealer()
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN)
        revealer.set_transition_duration(260)
        picker = Gtk.Grid(column_homogeneous=True, column_spacing=6, row_spacing=6)
        picker.add_css_class("theme-picker")
        themes = [
            ("mono-mesh", "Mono Mesh"),
            ("desert-dusk", "Desert Dusk"),
            ("acid-statue", "Acid Statue"),
            ("nighthawks", "Nighthawks"),
            ("lunar-peaks", "Lunar Peaks"),
            ("obsidian-ridge", "Obsidian Ridge"),
            ("cold-concrete", "Cold Concrete"),
            ("gilded-contours", "Gilded Contours"),
        ]
        theme_cards = {}
        for i, (name, label) in enumerate(themes):
            card = Gtk.Button()
            card.add_css_class("theme-card")
            card.add_css_class(f"swatch-{name}")
            inner = self._box(Gtk.Orientation.VERTICAL, spacing=5)
            sw = Gtk.Box()
            sw.add_css_class("theme-swatch")
            sw.add_css_class(f"swatch-{name}")
            inner.append(sw)
            inner.append(self._label(label, "theme-card-name", xalign=0.5))
            card.set_child(inner)
            picker.attach(card, i % 4, i // 4, 1, 1)
            theme_cards[name] = card

            def _on_theme_pick(_b, n=name):
                self._pending_set("active_theme", n, ttl_s=20)
                for nn, cc in theme_cards.items():
                    self._set_class(cc, "active-theme", nn == n)
                act_switch_theme(n)
            card.connect("clicked", _on_theme_pick)
        revealer.set_child(picker)
        # Collapsed by default — keep it out of the layout entirely so the box
        # doesn't reserve its inter-child spacing below the footer (dead space).
        revealer.set_visible(False)
        view.append(revealer)

        def _on_revealed(_r, _p):
            if not revealer.get_reveal_child():
                revealer.set_visible(False)
        revealer.connect("notify::child-revealed", _on_revealed)

        def _on_theme(_b):
            opened = not revealer.get_reveal_child()
            if opened:
                revealer.set_visible(True)
            revealer.set_reveal_child(opened)
            self._set_class(theme_btn, "on", opened)
        theme_btn.connect("clicked", _on_theme)

        # ── Refresh ──
        def refresh(s):
            meta.set_label(f"{s.get('hostname', '')} · {s.get('time', '')}")

            # Wi-Fi tile
            w = s["wifi"]
            if not w["enabled"]:
                wifi_t.glyph.set_label(G["wifi"])
                wifi_t.sub.set_label("Off")
                self._set_class(wifi_t.widget, "on", False)
            elif w["connected"] and w["ssid"]:
                wifi_t.glyph.set_label(self._wifi_glyph(w["signal_pct"]))
                wifi_t.sub.set_label(self._short(w["ssid"], 14))
                self._set_class(wifi_t.widget, "on", True)
            else:
                wifi_t.glyph.set_label(G["wifi"])
                wifi_t.sub.set_label("Off")
                self._set_class(wifi_t.widget, "on", False)

            # Bluetooth tile
            b = s["bluetooth"]
            if not b["powered"]:
                bt_t.glyph.set_label(G["bluetooth"])
                bt_t.sub.set_label("Off")
                self._set_class(bt_t.widget, "on", False)
            elif b["primary"]:
                bt_t.glyph.set_label(G["bluetooth_on"])
                bat = b["primary"].get("battery")
                bat_s = f" · {bat}%" if bat is not None else ""
                bt_t.sub.set_label(self._short(f"{b['primary']['alias']}{bat_s}", 14))
                self._set_class(bt_t.widget, "on", True)
            else:
                bt_t.glyph.set_label(G["bluetooth_on"])
                bt_t.sub.set_label(f"{len(b['devices'])} paired")
                self._set_class(bt_t.widget, "on", True)

            # VPN tile
            caps = s.get("caps", {})
            ts_cap = caps.get("tailscale", True)
            mv_cap = caps.get("mullvad", True)
            ts = s["tailscale"]
            mv = s["mullvad"]
            ts_on = ts_cap and ts["enabled"]
            mv_on = mv_cap and mv["connected"]
            vpn_t.glyph.set_label(G["shield"])
            if not ts_cap and not mv_cap:
                vpn_t.sub.set_label("n/a")
            elif ts_on and mv_on:
                vpn_t.sub.set_label("TS + MV")
            elif ts_on:
                vpn_t.sub.set_label("Tailscale")
            elif mv_on:
                vpn_t.sub.set_label(self._short(mv["city"] or mv["country"] or "Mullvad", 14))
            else:
                vpn_t.sub.set_label("Off")
            self._set_class(vpn_t.widget, "on", ts_on or mv_on)

            # Focus tile (Do Not Disturb)
            d = s["dnd"]
            focus_t.glyph.set_label(G["bell_off"])
            if not dnd_available:
                focus_t.sub.set_label("n/a")
                self._set_class(focus_t.widget, "on", False)
            elif d["enabled"]:
                focus_t.sub.set_label(d["mode"] or "On")
                self._set_class(focus_t.widget, "on", True)
            else:
                focus_t.sub.set_label("Off")
                self._set_class(focus_t.widget, "on", False)

            # Awake / Night toggle tiles
            awake_on = self.effective("keep_awake", s.get("keep_awake", False))
            self._set_class(awake_t.widget, "on", awake_on)
            awake_t.sub.set_label("On" if awake_on else "Off")

            if not night_light_available:
                night_t.sub.set_label("n/a")
                self._set_class(night_t.widget, "on", False)
            else:
                night_on = self.effective("night_light", s.get("night_light", False))
                self._set_class(night_t.widget, "on", night_on)
                night_t.sub.set_label("On" if night_on else "Off")

            # Sliders
            a = s["audio"]
            self._set_slider_polled(vol_s, a["sink_volume_pct"])
            vol_s.glyph_btn.set_label(
                G["volume_mute"]
                if self.effective("audio.sink_muted", a["sink_muted"])
                else G["volume"]
            )
            if brightness_available:
                self._set_slider_polled(brt_s, s["brightness"]["percent"])
            self._set_slider_polled(mic_s, a["source_volume_pct"])
            mic_s.glyph_btn.set_label(
                G["mic_off"]
                if self.effective("audio.source_muted", a["source_muted"])
                else G["mic"]
            )

            # Power profile (respect optimistic pending)
            profile = self.effective("power_profile", s["power_profile"])
            for key, btn in zip(pp_keys, pp.buttons):
                self._set_class(btn, "active", key == profile)

            # Theme cards (pending until rebuild completes)
            active_theme = self.effective("active_theme", s.get("active_theme", ""))
            for name, card in theme_cards.items():
                self._set_class(card, "active-theme", name == active_theme)

            # Now playing
            n = s["now_playing"]
            if n["title"]:
                self._set_class(art_fallback, "idle", False)
                art_note.set_visible(False)
                self._set_class(np_title, "np-empty", False)
                np_title.set_xalign(0)  # real titles read left-aligned
                np_title.set_label(self._short(n["title"], 30))
                np_artist.set_visible(True)
                parts = [p for p in [n["artist"], n["player"]] if p]
                np_artist.set_label(self._short(" — ".join(parts), 34))
            else:
                # Keep the music-icon tile as a calm idle affordance; soften the
                # placeholder text (np-empty) and centre it across the middle so
                # it reads as a quiet status line rather than a heavy title
                # crammed against the tile.
                self._set_class(art_fallback, "idle", True)
                art_note.set_visible(True)
                self._set_class(np_title, "np-empty", True)
                np_title.set_xalign(0.5)
                np_title.set_label("Nothing playing")
                # Hide (not just blank) the artist line — an empty label still
                # reserves a row, which pushes the centered title above the
                # tile/icon midline.
                np_artist.set_label("")
                np_artist.set_visible(False)
            play_btn.set_label(
                G["pause"] if n["status"] == "Playing" else G["play"]
            )

            # Album art
            art_url = n.get("art_url", "")
            if art_url:
                if art_url in actions._art_cache:
                    path = actions._art_cache[art_url]
                    if path and os.path.exists(path):
                        art_pic.set_filename(path)
                        art_pic.set_visible(True)
                    else:
                        art_pic.set_visible(False)
                elif art_url not in actions._art_pending:
                    def _on_art(path, url=art_url):
                        if path and os.path.exists(path):
                            art_pic.set_filename(path)
                            art_pic.set_visible(True)
                        return False
                    actions._fetch_art(art_url, _on_art)
            else:
                art_pic.set_visible(False)

            # Footer battery
            bat = s["battery"]
            charging = bat["status"] in ("Charging", "Full")
            bat_glyph.set_label(self._battery_glyph(bat["percent"], charging))
            bat_pct.set_label(f"{bat['percent']}%")
            meta_parts = []
            if bat["status"] == "Charging":
                meta_parts.append(f"{bat['time_str']}")
            elif bat["status"] != "Full" and bat["time_str"]:
                # "Full" needs no label — the 100% readout already says it.
                meta_parts.append(bat["time_str"])
            if s["cpu_temp"] is not None:
                meta_parts.append(f"{s['cpu_temp']}°")
            bat_meta.set_label(("· " + " · ".join(meta_parts)) if meta_parts else "")

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
