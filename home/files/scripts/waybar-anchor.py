#!/usr/bin/env python3
"""Waybar anchor bar status — single-pill control-center trigger.

Outputs JSON: always a dot, conditional indicators for DND,
mic-muted, and battery (hidden when AC+100%). Dot recolors by severity.
"""

import json
import os
import re
import subprocess


def _load_colors():
    path = os.path.expanduser("~/.config/waybar/colors.css")
    colors = {}
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"@define-color\s+(\w+)\s+#([0-9a-fA-F]{6})", line)
                if m:
                    colors[m.group(1)] = "#" + m.group(2)
    except OSError:
        pass
    return colors


def _run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=1.5)
        return r.stdout, r.returncode == 0
    except Exception:
        return "", False


def _bat_glyph(pct, charging):
    if charging:
        return "󰂄"
    glyphs = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    return glyphs[min(pct // 10, 9)]


def main():
    c = _load_colors()
    amber = c.get("amber", "#8aa4b8")
    warn = "#e88920"
    dim = c.get("orange", "#666666")

    indicators = []
    classes = []
    severity = 0  # 0 = quiet, 1 = amber, 2 = warn

    # ── DND ────────────────────────────────────────────────────────
    dnd_out, dnd_ok = _run(["makoctl", "mode"])
    if dnd_ok:
        modes = [m.strip() for m in dnd_out.splitlines() if m.strip()]
        if any(m != "default" for m in modes):
            indicators.append(f'<span color="{amber}">󰂛</span>')
            classes.append("dnd")
            severity = max(severity, 1)

    # ── Mic muted ──────────────────────────────────────────────────
    mic_out, _ = _run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"])
    if "MUTED" in mic_out:
        indicators.append(f'<span color="{warn}">󰍭</span>')
        classes.append("mic")
        severity = max(severity, 2)

    # ── Battery ────────────────────────────────────────────────────
    bat_pct = None
    bat_charging = False
    bat_full = False
    ac_online = False
    try:
        psu_root = "/sys/class/power_supply"
        entries = sorted(os.listdir(psu_root))
        for e in entries:
            p = f"{psu_root}/{e}"
            try:
                ptype = open(f"{p}/type").read().strip()
            except OSError:
                continue
            if ptype == "Mains":
                try:
                    if open(f"{p}/online").read().strip() == "1":
                        ac_online = True
                except OSError:
                    pass
        for e in entries:
            if not e.startswith("BAT"):
                continue
            p = f"{psu_root}/{e}"
            if not os.path.isdir(p):
                continue
            bat_pct = int(open(f"{p}/capacity").read().strip())
            status = open(f"{p}/status").read().strip()
            # "Not charging" with AC online = charge-threshold reached / full.
            bat_charging = status in ("Charging", "Full") or ac_online
            # Firmware often flips to "Full" a hair shy of 100% (e.g. 99%);
            # treat that as full so the indicator hides on AC.
            bat_full = status == "Full" or bat_pct >= 100
            break
    except (OSError, ValueError):
        pass

    if bat_pct is not None and not (bat_charging and bat_full):
        if bat_pct <= 20:
            bat_color = warn
            severity = max(severity, 2)
        elif bat_pct <= 40:
            bat_color = amber
            severity = max(severity, 1)
        else:
            bat_color = None  # default text color

        glyph = _bat_glyph(bat_pct, bat_charging)
        bat_text = f"{glyph}  {bat_pct}%"
        if bat_color:
            bat_text = f'<span color="{bat_color}">{bat_text}</span>'
        indicators.append(bat_text)
        classes.append("bat")

    # ── Dot ────────────────────────────────────────────────────────
    if severity == 2:
        dot_color = warn
        classes.append("warn-glow")
    elif severity == 1:
        dot_color = amber
        classes.append("glow")
    else:
        dot_color = dim
        classes.append("quiet")

    dot = f'<span size="6144" color="{dot_color}">●</span>'
    parts = [dot] + indicators
    text = "  ".join(parts)

    print(json.dumps({
        "text": text,
        "class": " ".join(classes),
        "tooltip": "Control Center",
    }))


if __name__ == "__main__":
    main()
