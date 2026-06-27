"""GTK CSS for the panel. Produced at startup once the theme palette is loaded."""

from .constants import DEFAULTS, PANEL_CONTENT_WIDTH, PANEL_PADDING
from .theme import h2rgb


def build_css(colors):
    bg = h2rgb(colors.get("bg", DEFAULTS["bg"]))
    brown = h2rgb(colors.get("brown", DEFAULTS["brown"]))
    orange = h2rgb(colors.get("orange", DEFAULTS["orange"]))
    amber = h2rgb(colors.get("amber", DEFAULTS["amber"]))
    text = h2rgb(colors.get("text", DEFAULTS["text"]))

    def rgba(rgb, a):
        return f"rgba({rgb[0]}, {rgb[1]}, {rgb[2]}, {a})"

    return f"""
    * {{
        font-family: "Inter", "JetBrainsMono Nerd Font", sans-serif;
        font-size: 12px;
        color: {rgba(text, 0.92)};
    }}
    .tile-glyph, .glyph-btn, .chip-glyph, .icon-btn, .back-btn,
    .hero-icon-wrap, .vpn-icon, .di-icon {{
        font-family: "JetBrainsMono Nerd Font", "Inter", sans-serif;
    }}
    window {{ background: transparent; }}

    #panel {{
        min-width: {PANEL_CONTENT_WIDTH}px;
        padding: {PANEL_PADDING}px;
        border-radius: 15px;
        border: 1px solid {rgba(orange, 0.28)};
        background: linear-gradient(180deg,
            {rgba(bg, 0.985)} 0%,
            {rgba(brown, 0.955)} 100%);
        box-shadow:
            0 24px 56px rgba(0, 0, 0, 0.35),
            inset 0 1px 0 rgba(255, 255, 255, 0.03);
    }}

    .panel-stack {{
        margin: 0;
        min-width: {PANEL_CONTENT_WIDTH}px;
    }}

    .panel-header {{ margin-bottom: 4px; }}
    .panel-title {{ font-size: 13px; font-weight: 600; letter-spacing: 0.03em; }}
    .panel-title.with-back {{ font-size: 14px; }}
    .panel-meta {{ color: {rgba(text, 0.42)}; font-size: 10px;
                   letter-spacing: 0.08em; }}

    .live-dot {{
        min-width: 7px; min-height: 7px;
        border-radius: 999px;
        color: {rgba(amber, 1.0)};
        font-size: 9px;
    }}

    .back-btn {{
        min-width: 28px; min-height: 28px;
        padding: 0 6px;
        border-radius: 8px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.04);
        color: {rgba(text, 0.8)};
        font-size: 16px;
        box-shadow: none;
    }}
    .back-btn:hover {{
        background: rgba(255, 255, 255, 0.08);
        color: {rgba(text, 1.0)};
    }}

    /* Tile grid */
    .tile {{
        padding: 9px;
        border-radius: 10px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.02);
        color: {rgba(text, 0.88)};
        box-shadow: none;
    }}
    .tile:hover {{ background: rgba(255, 255, 255, 0.05); }}
    .tile.on {{
        border-color: {rgba(amber, 0.45)};
        background: {rgba(amber, 0.10)};
    }}
    .tile-icon {{ margin-bottom: 4px; }}
    .tile-glyph {{
        min-width: 32px; min-height: 32px;
        padding: 0;
        border-radius: 8px;
        background: rgba(255, 255, 255, 0.05);
        color: {rgba(text, 0.78)};
        font-size: 13px;
    }}
    .tile.on .tile-glyph {{
        background: {rgba(amber, 0.22)};
        color: {rgba(amber, 1.0)};
    }}
    .tile-chevron {{ color: {rgba(text, 0.34)}; font-size: 11px; }}
    .tile.on .tile-chevron {{ color: {rgba(amber, 0.85)}; }}
    .tile-title {{ font-size: 12px; font-weight: 600; }}
    .tile-sub {{ color: {rgba(text, 0.46)}; font-size: 10px; }}
    .tile.on .tile-sub {{ color: {rgba(amber, 0.86)}; }}
    .tile-badge {{
        padding: 2px 6px;
        border-radius: 999px;
        background: {rgba(amber, 0.15)};
        color: {rgba(amber, 1.0)};
        font-size: 9px;
        font-weight: 600;
        letter-spacing: 0.06em;
    }}

    /* Generic surface + sections */
    .surface {{
        padding: 9px;
        border-radius: 11px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.03);
    }}
    .section-label {{ margin-bottom: 4px; margin-top: 4px; }}
    .section-text, .section-label label {{
        color: {rgba(text, 0.42)};
        font-size: 10px;
        font-weight: 500;
        letter-spacing: 0.08em;
    }}
    .section-action {{
        padding: 2px 6px;
        background: transparent;
        border: none;
        color: {rgba(text, 0.62)};
        font-size: 10px;
        box-shadow: none;
    }}
    .section-action:hover {{ color: {rgba(text, 1.0)}; }}

    /* Sliders */
    .slider-row {{ margin: 0; min-width: 284px; }}
    .glyph-btn {{
        min-width: 26px; min-height: 26px;
        padding: 0;
        border-radius: 8px;
        border: none;
        background: rgba(255, 255, 255, 0.04);
        color: {rgba(text, 0.78)};
        box-shadow: none;
    }}
    .glyph-btn:hover {{
        background: rgba(255, 255, 255, 0.08);
        color: {rgba(text, 1.0)};
    }}
    .slider-track {{
        min-height: 6px;
        margin: 10px 0;
        border-radius: 999px;
        background: rgba(255, 255, 255, 0.08);
    }}
    .slider-fill {{
        min-height: 6px;
        border-radius: 999px;
        background: linear-gradient(90deg,
            {rgba(amber, 0.55)}, {rgba(text, 0.92)});
    }}
    .slider-knob {{
        min-width: 12px; min-height: 12px;
        margin-top: -3px;
        border-radius: 999px;
        background: {rgba(text, 1.0)};
    }}
    .slider-value {{
        min-width: 24px;
        color: {rgba(text, 0.66)};
        font-size: 11px;
    }}
    .slider-aux {{
        padding: 4px 0;
        min-width: 74px;
        min-height: 24px;
        background: transparent;
        border: none;
        color: {rgba(text, 0.5)};
        font-size: 10px;
        box-shadow: none;
    }}
    .slider-aux-label {{
        min-width: 74px;
        color: {rgba(text, 0.5)};
        font-size: 10px;
    }}
    .slider-aux:hover .slider-aux-label {{ color: {rgba(text, 1.0)}; }}
    .slider-aux:hover {{ color: {rgba(text, 1.0)}; }}
    .app-slider {{ margin: 6px 0 0 0; min-height: 4px; }}
    .app-slider .slider-fill {{ min-height: 4px; }}

    /* Segmented */
    .segmented {{
        padding: 4px;
        border-radius: 12px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.04);
    }}
    .seg {{
        padding: 6px 8px;
        min-height: 26px;
        border-radius: 9px;
        border: none;
        background: transparent;
        color: {rgba(text, 0.62)};
        font-size: 11px;
        box-shadow: none;
    }}
    .seg:hover {{ color: {rgba(text, 1.0)}; }}
    .seg.active {{
        color: {rgba(amber, 1.0)};
        background: {rgba(amber, 0.14)};
        box-shadow: inset 0 0 0 1px {rgba(amber, 0.32)};
    }}

    /* Chips */
    .chip-row {{ margin: 0; }}
    .chip {{
        padding: 7px 11px;
        border-radius: 10px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.02);
        color: {rgba(text, 0.74)};
        font-size: 11px;
        box-shadow: none;
    }}
    .chip:hover {{
        background: rgba(255, 255, 255, 0.05);
        color: {rgba(text, 1.0)};
    }}
    .chip.on {{
        border-color: {rgba(amber, 0.45)};
        background: {rgba(amber, 0.12)};
        color: {rgba(amber, 1.0)};
    }}
    .chip-glyph {{ font-size: 12px; }}

    /* Theme picker */
    .theme-picker {{
        padding: 8px 0 4px;
    }}
    .theme-card {{
        padding: 6px;
        border-radius: 10px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.025);
        box-shadow: none;
    }}
    .theme-card:hover {{ background: rgba(255, 255, 255, 0.05); }}
    .theme-card.active-theme {{
        border-color: {rgba(amber, 0.55)};
        background: {rgba(amber, 0.10)};
    }}
    .theme-card-name {{
        font-size: 10px;
        color: {rgba(text, 0.72)};
    }}
    .theme-card.active-theme .theme-card-name {{
        color: {rgba(amber, 1.0)};
    }}
    .theme-swatch {{
        min-height: 22px;
        border-radius: 6px;
        border: 1px solid rgba(255, 255, 255, 0.05);
    }}
    .theme-swatch.swatch-mono-mesh {{
        background: linear-gradient(90deg, #2a2a2a 0%, #888888 50%, #cccccc 100%);
    }}
    .theme-swatch.swatch-desert-dusk {{
        background: linear-gradient(90deg, #4a3728 0%, #c46e1a 50%, #e8890c 100%);
    }}
    .theme-swatch.swatch-acid-statue {{
        background: linear-gradient(90deg, #2e3a4a 0%, #4a7a6a 50%, #a8e840 100%);
    }}
    .theme-swatch.swatch-nighthawks {{
        background: linear-gradient(90deg, #2a3040 0%, #4a5568 50%, #8aa4b8 100%);
    }}
    .theme-swatch.swatch-lunar-peaks {{
        background: linear-gradient(90deg, #151718 0%, #a6a6a6 50%, #d8d8d8 100%);
    }}
    .theme-swatch.swatch-obsidian-ridge {{
        background: linear-gradient(90deg, #1d1d1d 0%, #5f5f5f 50%, #8f8f8f 100%);
    }}
    .theme-swatch.swatch-cold-concrete {{
        background: linear-gradient(90deg, #111820 0%, #9bb8bd 50%, #d8d2b8 100%);
    }}
    .theme-swatch.swatch-gilded-contours {{
        background: linear-gradient(90deg, #0d1830 0%, #d3ad7a 50%, #e0c290 100%);
    }}

    /* Now playing */
    .nowplaying {{
        padding: 10px 12px;
        border-radius: 13px;
        border: 1px solid {rgba(orange, 0.16)};
        background: rgba(255, 255, 255, 0.025);
    }}
    .album-art {{
        min-width: 42px; min-height: 42px;
        border-radius: 9px;
        background: linear-gradient(135deg,
            {rgba(amber, 0.55)} 0%,
            {rgba(orange, 0.7)} 100%);
    }}
    .album-art-pic {{
        min-width: 42px; min-height: 42px;
        border-radius: 9px;
    }}
    .np-title {{ font-weight: 600; }}
    .np-artist {{ color: {rgba(text, 0.54)}; font-size: 10.5px; }}
    .np-player {{ color: {rgba(text, 0.28)}; font-size: 9px; }}

    /* Stat grid + action row + icon buttons */
    .stat-cell {{
        padding: 10px 4px;
        border-radius: 12px;
        background: rgba(255, 255, 255, 0.025);
        border: 1px solid {rgba(orange, 0.16)};
    }}
    .stat-value {{ font-size: 15px; font-weight: 600; }}
    .stat-cell.accent .stat-value {{ color: {rgba(amber, 1.0)}; }}
    .stat-label {{
        color: {rgba(text, 0.46)};
        font-size: 9px;
        letter-spacing: 0.08em;
    }}

    .action-row {{}}
    .icon-btn {{
        min-height: 38px;
        padding: 0 8px;
        border-radius: 9px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.04);
        color: {rgba(text, 0.74)};
        box-shadow: none;
        font-size: 14px;
    }}
    .icon-btn:hover {{
        background: rgba(255, 255, 255, 0.08);
        color: {rgba(text, 1.0)};
    }}
    .icon-btn.danger:hover {{
        color: rgb(232, 137, 32);
        border-color: rgba(232, 137, 32, 0.4);
    }}
    .icon-btn.primary {{
        background: {rgba(amber, 0.18)};
        color: {rgba(amber, 1.0)};
        border-color: {rgba(amber, 0.4)};
    }}

    /* Switch */
    .switch {{
        min-width: 38px; min-height: 22px;
        padding: 2px;
        border-radius: 999px;
        border: 1px solid {rgba(orange, 0.28)};
        background: rgba(255, 255, 255, 0.06);
        box-shadow: none;
    }}
    .switch.on {{
        background: {rgba(amber, 0.28)};
        border-color: {rgba(amber, 0.5)};
    }}
    .switch-knob {{
        min-width: 16px; min-height: 16px;
        border-radius: 999px;
        background: {rgba(text, 0.92)};
    }}
    .switch.on .switch-knob {{
        margin-left: 16px;
        background: {rgba(amber, 1.0)};
    }}

    /* Drawer list + items */
    .drawer-list {{
        padding: 6px;
        border-radius: 13px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.03);
    }}
    .drawer-item {{
        padding: 8px;
        border-radius: 9px;
        border: none;
        background: transparent;
        box-shadow: none;
    }}
    .drawer-item:hover {{ background: rgba(255, 255, 255, 0.04); }}
    .drawer-item.active {{ background: {rgba(amber, 0.10)}; }}
    .drawer-item.subtle .di-name {{ color: {rgba(text, 0.6)}; }}
    .di-icon {{
        color: {rgba(text, 0.78)};
        font-size: 13px;
    }}
    .drawer-item.active .di-icon {{ color: {rgba(amber, 1.0)}; }}
    .di-name {{ font-weight: 500; }}
    .di-sub {{ color: {rgba(text, 0.5)}; font-size: 10px; }}
    .di-right {{
        color: {rgba(text, 0.5)};
        font-size: 10px;
        font-weight: 500;
        letter-spacing: 0.06em;
    }}
    .drawer-item.active .di-right {{ color: {rgba(amber, 1.0)}; }}

    .status-dot {{
        min-width: 6px; min-height: 6px;
        border-radius: 999px;
        background: {rgba(text, 0.25)};
    }}
    .status-dot.online {{ background: rgb(120, 200, 120); }}
    .status-dot.this {{ background: {rgba(amber, 1.0)}; }}

    .drawer-row {{
        padding: 10px;
        border-radius: 13px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.025);
    }}
    .drawer-select {{
        padding: 5px 9px;
        border-radius: 8px;
        border: none;
        background: rgba(255, 255, 255, 0.05);
        color: {rgba(text, 0.78)};
        font-size: 11px;
        box-shadow: none;
    }}
    .drawer-select:hover {{
        background: rgba(255, 255, 255, 0.08);
        color: {rgba(text, 1.0)};
    }}

    /* Hero card (detail views) */
    .hero-card {{
        padding: 14px;
        border-radius: 14px;
        border: 1px solid {rgba(amber, 0.32)};
        background: linear-gradient(135deg,
            {rgba(amber, 0.14)} 0%,
            {rgba(amber, 0.04)} 100%);
    }}
    .hero-icon-wrap {{
        min-width: 44px; min-height: 44px;
        padding: 0;
        border-radius: 12px;
        background: {rgba(amber, 0.22)};
        color: {rgba(amber, 1.0)};
        font-size: 18px;
    }}
    .hero-title {{ font-weight: 600; font-size: 13px; }}
    .hero-sub {{ color: {rgba(text, 0.6)}; font-size: 10.5px; }}
    .hero-big {{
        font-size: 18px;
        font-weight: 600;
        color: {rgba(amber, 1.0)};
    }}
    .hero-small {{
        color: {rgba(text, 0.5)};
        font-size: 9px;
        letter-spacing: 0.08em;
    }}

    /* VPN sections */
    .vpn-section {{
        padding: 12px;
        border-radius: 14px;
        border: 1px solid {rgba(orange, 0.18)};
        background: rgba(255, 255, 255, 0.025);
    }}
    .vpn-section.off {{ opacity: 0.62; }}
    .vpn-icon {{
        min-width: 38px; min-height: 38px;
        padding: 0;
        border-radius: 11px;
        background: {rgba(amber, 0.18)};
        color: {rgba(amber, 1.0)};
        font-size: 16px;
    }}
    .vpn-section.off .vpn-icon {{
        background: rgba(255, 255, 255, 0.05);
        color: {rgba(text, 0.5)};
    }}
    .vpn-name {{ font-weight: 600; font-size: 13px; }}
    .vpn-sub {{ color: {rgba(text, 0.55)}; font-size: 10.5px; }}
    .vpn-stat {{
        padding: 8px;
        border-radius: 10px;
        background: rgba(255, 255, 255, 0.025);
        border: 1px solid {rgba(orange, 0.14)};
    }}
    .vpn-stat-cell {{ padding: 4px 2px; }}
    .vpn-stat-value {{ font-size: 12px; font-weight: 600; }}
    .vpn-stat-label {{
        color: {rgba(text, 0.42)};
        font-size: 9px;
        letter-spacing: 0.08em;
    }}

    /* DND */
    .dnd-prompt {{
        color: {rgba(text, 0.6)};
        font-size: 11px;
        margin-bottom: 4px;
    }}

    /* Mic level meter */
    .level-meter {{
        padding: 12px;
        min-height: 64px;
        border-radius: 12px;
        border: 1px solid {rgba(orange, 0.16)};
        background: rgba(255, 255, 255, 0.025);
    }}
    .meter-bar {{
        min-width: 6px;
        background: {rgba(text, 0.16)};
        border-radius: 2px;
    }}
    .meter-bar.active {{
        background: linear-gradient(180deg,
            {rgba(amber, 1.0)} 0%,
            {rgba(amber, 0.55)} 100%);
    }}

    /* Ghost button (footer of detail views) */
    .ghost-btn {{
        padding: 9px 12px;
        border-radius: 11px;
        border: 1px solid {rgba(orange, 0.2)};
        background: rgba(255, 255, 255, 0.02);
        color: {rgba(text, 0.74)};
        font-size: 11px;
        box-shadow: none;
    }}
    .ghost-btn:hover {{
        background: rgba(255, 255, 255, 0.05);
        color: {rgba(text, 1.0)};
    }}
    """
