"""Home view: tile grid, sliders, power profile, quick toggles, now playing, stats."""

import os

from gi.repository import Gtk

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
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")

        # Header
        header = self._box(Gtk.Orientation.HORIZONTAL, css="panel-header")
        title = self._box(Gtk.Orientation.HORIZONTAL, spacing=8, css="panel-title")
        live = self._label(G["live_dot"], "live-dot")
        title.append(live)
        title.append(self._label("Control Center"))
        header.append(title)
        header.append(Gtk.Box(hexpand=True))
        meta = self._label("", "panel-meta", xalign=1)
        header.append(meta)
        view.append(header)

        # Tile grid 2×2
        wifi_t = self._tile("Wi-Fi", view="wifi")
        bt_t = self._tile("Bluetooth", view="bluetooth")
        vpn_t = self._tile("VPN", view="vpn")
        dnd_t = self._tile("Do Not Disturb", view="dnd")

        grid = Gtk.Grid(
            column_homogeneous=True, column_spacing=8, row_spacing=8
        )
        grid.add_css_class("tile-grid")
        grid.attach(wifi_t.widget, 0, 0, 1, 1)
        grid.attach(bt_t.widget, 1, 0, 1, 1)
        grid.attach(vpn_t.widget, 0, 1, 1, 1)
        grid.attach(dnd_t.widget, 1, 1, 1, 1)
        view.append(grid)

        # Sliders
        vol_s = self._slider_row(
            G["volume"], aux_label="Speakers ›", aux_view="volume",
        )
        brt_s = self._slider_row(G["sun"], aux_label="Auto")
        mic_s = self._slider_row(
            G["mic"], aux_label="Internal ›", aux_view="microphone",
        )
        sliders = self._box(
            Gtk.Orientation.VERTICAL, spacing=12,
            css=["surface", "slider-block"],
        )
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

        # Power profile
        view.append(self._section_label("Power Profile", action="Detailed"))
        pp = self._segmented(
            [(G["leaf"], "Saver"), (G["gauge"], "Balanced"),
             (G["zap"], "Performance")],
        )
        view.append(pp.widget)
        pp_keys = ["power-saver", "balanced", "performance"]

        for key, btn in zip(pp_keys, pp.buttons):
            def _on_pp(_b, k=key):
                self._pending_set("power_profile", k, ttl_s=3)
                # Optimistic visual flip
                for kk, bb in zip(pp_keys, pp.buttons):
                    self._set_class(bb, "active", kk == k)
                act_set_power_profile(k)
            btn.connect("clicked", _on_pp)

        # Quick toggles + theme picker
        view.append(self._section_label("Quick Toggles", action="Edit"))
        chip_row = self._box(Gtk.Orientation.HORIZONTAL, spacing=6, css="chip-row")
        ka_chip = self._chip(G["coffee"], "Keep Awake")
        nl_chip = self._chip(G["moon"], "Night Light")
        nl_chip.set_sensitive(night_light_available)
        theme_chip = self._chip(G["palette"], "Theme", css="theme-trigger")
        chip_row.append(ka_chip)
        chip_row.append(nl_chip)
        chip_row.append(theme_chip)
        view.append(chip_row)

        def _on_keep_awake(b):
            # _chip auto-toggle already flipped .on; read new desired state
            want = b.has_css_class("on")
            self._pending_set("keep_awake", want, ttl_s=4)
            act_keep_awake(want)
        ka_chip.connect("clicked", _on_keep_awake)

        def _on_night_light(b):
            want = b.has_css_class("on")
            self._pending_set("night_light", want, ttl_s=4)
            act_night_light(want)
        nl_chip.connect("clicked", _on_night_light)

        # Theme picker (revealer)
        revealer = Gtk.Revealer()
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN)
        revealer.set_transition_duration(260)
        picker = Gtk.Grid(column_homogeneous=True, column_spacing=6,
                          row_spacing=6)
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
                # Theme switch triggers a rebuild; can take a few seconds.
                self._pending_set("active_theme", n, ttl_s=20)
                for nn, cc in theme_cards.items():
                    self._set_class(cc, "active-theme", nn == n)
                act_switch_theme(n)
            card.connect("clicked", _on_theme_pick)
        revealer.set_child(picker)
        view.append(revealer)

        def _on_theme(_b):
            opened = not revealer.get_reveal_child()
            revealer.set_reveal_child(opened)
            if opened:
                theme_chip.add_css_class("expanded")
            else:
                theme_chip.remove_css_class("expanded")
        theme_chip.connect("clicked", _on_theme)

        # Now playing
        view.append(self._section_label("Now Playing"))

        np = self._box(Gtk.Orientation.HORIZONTAL, spacing=12, css="nowplaying")
        art_fallback = Gtk.Box()
        art_fallback.add_css_class("album-art")
        art_pic = Gtk.Picture()
        art_pic.add_css_class("album-art-pic")
        art_pic.set_content_fit(Gtk.ContentFit.COVER)
        art_pic.set_visible(False)
        art_overlay = Gtk.Overlay()
        art_overlay.set_size_request(42, 42)
        art_overlay.set_child(art_fallback)
        art_overlay.add_overlay(art_pic)
        np.append(art_overlay)
        track = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        track.set_hexpand(True)
        np_title = self._label("", "np-title")
        np_artist = self._label("", "np-artist")
        np_player = self._label("", "np-player")
        track.append(np_title)
        track.append(np_artist)
        track.append(np_player)
        np.append(track)
        ctrl = self._box(Gtk.Orientation.HORIZONTAL, spacing=4)
        skip_back_btn = self._icon_btn(G["skip_back"])
        ctrl.append(skip_back_btn)
        play_btn = self._icon_btn(G["play"])
        play_btn.add_css_class("primary")
        ctrl.append(play_btn)
        skip_fwd_btn = self._icon_btn(G["skip_forward"])
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

        # Stat grid (battery, remaining, cpu)
        stats = Gtk.Grid(column_homogeneous=True, column_spacing=6)
        stats.add_css_class("stat-grid")
        bat_cell = self._box(Gtk.Orientation.VERTICAL, css="stat-cell")
        bat_cell.add_css_class("accent")
        bat_value = self._label("", "stat-value", xalign=0.5)
        bat_cell.append(bat_value)
        bat_cell.append(self._label("battery", "stat-label", xalign=0.5))
        stats.attach(bat_cell, 0, 0, 1, 1)

        rem_cell = self._box(Gtk.Orientation.VERTICAL, css="stat-cell")
        rem_value = self._label("", "stat-value", xalign=0.5)
        rem_cell.append(rem_value)
        rem_label = self._label("remaining", "stat-label", xalign=0.5)
        rem_cell.append(rem_label)
        stats.attach(rem_cell, 1, 0, 1, 1)

        cpu_cell = self._box(Gtk.Orientation.VERTICAL, css="stat-cell")
        cpu_value = self._label("", "stat-value", xalign=0.5)
        cpu_cell.append(cpu_value)
        cpu_cell.append(self._label("cpu", "stat-label", xalign=0.5))
        stats.attach(cpu_cell, 2, 0, 1, 1)
        view.append(stats)

        # Action row
        action_row = Gtk.Grid(column_homogeneous=True, column_spacing=6)
        action_row.add_css_class("action-row")
        lock_btn = self._icon_btn(G["lock"])
        sleep_btn = self._icon_btn(G["sleep"])
        power_btn = self._icon_btn(G["power"], danger=True)
        action_row.attach(lock_btn, 0, 0, 1, 1)
        action_row.attach(sleep_btn, 1, 0, 1, 1)
        action_row.attach(power_btn, 2, 0, 1, 1)
        view.append(action_row)

        lock_btn.connect("clicked", lambda _b: (act_lock(), self.quit()))
        sleep_btn.connect("clicked", lambda _b: (self.quit(), act_suspend()))
        power_btn.connect("clicked", lambda _b: (self.quit(), act_poweroff()))

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
                band = f" · {w['band']}" if w["band"] else ""
                wifi_t.sub.set_label(self._short(f"{w['ssid']}{band}", 30))
                self._set_class(wifi_t.widget, "on", True)
            else:
                wifi_t.glyph.set_label(G["wifi"])
                wifi_t.sub.set_label("Not connected")
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
                bt_t.sub.set_label(
                    self._short(f"{b['primary']['alias']}{bat_s}", 30)
                )
                self._set_class(bt_t.widget, "on", True)
            else:
                bt_t.glyph.set_label(G["bluetooth_on"])
                n = len(b["devices"])
                bt_t.sub.set_label(f"On · {n} paired")
                self._set_class(bt_t.widget, "on", True)

            # VPN tile
            caps = s.get("caps", {})
            ts_cap = caps.get("tailscale", True)
            mv_cap = caps.get("mullvad", True)
            ts = s["tailscale"]
            mv = s["mullvad"]
            ts_on = ts_cap and ts["enabled"]
            mv_on = mv_cap and mv["connected"]
            active = (1 if ts_on else 0) + (1 if mv_on else 0)
            vpn_t.glyph.set_label(G["shield"])
            if not ts_cap and not mv_cap:
                vpn_t.sub.set_label("Not installed")
            elif ts_on and ts["ip"]:
                vpn_t.sub.set_label(f"Tailscale · {ts['ip']}")
            elif mv_on:
                vpn_t.sub.set_label(f"Mullvad · {mv['city'] or mv['country']}")
            else:
                vpn_t.sub.set_label("Off")
            self._set_class(vpn_t.widget, "on", active > 0)
            vpn_t.badge.set_visible(False)

            # DND tile
            d = s["dnd"]
            dnd_t.glyph.set_label(G["bell_off"])
            if not caps.get("dnd", True):
                dnd_t.sub.set_label("Not installed")
                self._set_class(dnd_t.widget, "on", False)
            elif d["enabled"]:
                dnd_t.sub.set_label(f"On · {d['mode']}")
                self._set_class(dnd_t.widget, "on", True)
            else:
                dnd_t.sub.set_label("Off · all notifications")
                self._set_class(dnd_t.widget, "on", False)

            # Sliders
            a = s["audio"]
            self._set_slider_polled(vol_s, a["sink_volume_pct"])
            vol_s.glyph_btn.set_label(
                G["volume_mute"]
                if self.effective("audio.sink_muted", a["sink_muted"])
                else G["volume"]
            )
            if vol_s.aux:
                vol_s.aux_label.set_label(f"{self._short(a['sink_name'], 11)} ›")
            if brightness_available:
                self._set_slider_polled(brt_s, s["brightness"]["percent"])
                if brt_s.aux:
                    brt_s.aux_label.set_label("Auto")
            elif brt_s.aux:
                brt_s.aux_label.set_label("n/a")
            self._set_slider_polled(mic_s, a["source_volume_pct"])
            mic_s.glyph_btn.set_label(
                G["mic_off"]
                if self.effective("audio.source_muted", a["source_muted"])
                else G["mic"]
            )
            if mic_s.aux:
                mic_s.aux_label.set_label(f"{self._short(a['source_name'], 11)} ›")

            # Power profile (respect optimistic pending)
            profile = self.effective("power_profile", s["power_profile"])
            for key, btn in zip(pp_keys, pp.buttons):
                self._set_class(btn, "active", key == profile)

            # Quick toggle chips
            self._set_class(
                ka_chip, "on",
                self.effective("keep_awake", s.get("keep_awake", False)),
            )
            self._set_class(
                nl_chip, "on",
                night_light_available
                and self.effective("night_light", s.get("night_light", False)),
            )

            # Theme cards (pending until rebuild completes)
            active_theme = self.effective("active_theme", s.get("active_theme", ""))
            for name, card in theme_cards.items():
                self._set_class(card, "active-theme", name == active_theme)

            # Now playing
            n = s["now_playing"]
            if n["title"]:
                np_title.set_label(self._short(n["title"], 36))
                parts = [p for p in [n["artist"], n["album"]] if p]
                np_artist.set_label(self._short(" — ".join(parts), 50))
            else:
                np_title.set_label("Nothing playing")
                np_artist.set_label("")
            play_btn.set_label(
                G["pause"] if n["status"] == "Playing" else G["play"]
            )
            np_player.set_label(n["player"] or "")

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

            # Stats
            bat = s["battery"]
            bat_value.set_label(f"{bat['percent']}%")
            if bat["status"] == "Charging":
                rem_value.set_label(bat["time_str"])
                rem_label.set_label("until full")
            elif bat["status"] == "Full":
                rem_value.set_label("full")
                rem_label.set_label("plugged in")
            else:
                rem_value.set_label(bat["time_str"])
                rem_label.set_label("remaining")
            if s["cpu_temp"] is not None:
                cpu_value.set_label(f"{s['cpu_temp']}°")
            else:
                cpu_value.set_label("—")

        self._refreshers.append(refresh)
        refresh(self.state)
        return view
