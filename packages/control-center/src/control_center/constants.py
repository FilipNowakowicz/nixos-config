"""Module-wide constants: paths, panel geometry, state-key partitions, glyphs."""

STATE_PATH = "/tmp/control-center.json"
LOCK_PATH = "/tmp/control-center.lock"

VIEWS = ("home", "wifi", "bluetooth", "vpn", "dnd", "volume", "microphone")

# Now Playing only tracks MPRIS players whose bus name contains one of these
# (case-insensitive) substrings. Default: Spotify only, so browser/video tabs
# (YouTube in Firefox/Chromium, etc.) never hijack the media row. Add more
# players here (e.g. "mpd", "vlc") or set to () to track whatever is playing.
NOW_PLAYING_ALLOW = ("spotify",)

PANEL_MARGIN = 12
PANEL_PADDING = 9
PANEL_CONTENT_WIDTH = 308
PANEL_TOTAL_WIDTH = PANEL_CONTENT_WIDTH + (PANEL_PADDING * 2) + 2

FAST_STATE_KEYS = (
    "time", "hostname", "audio", "battery", "brightness", "power_profile",
    "dnd", "cpu_temp", "now_playing", "active_theme", "keep_awake",
    "night_light",
)
SLOW_STATE_KEYS = ("wifi", "bluetooth", "tailscale", "mullvad")

DEFAULTS = {
    "bg": "161a20",
    "brown": "1f252d",
    "orange": "4a5568",
    "amber": "8aa4b8",
    "text": "c8d0d8",
}

# Nerd Font glyphs — system already ships JetBrainsMono Nerd Font,
# so we use codepoints rather than embedded SVG.
G = {
    "wifi": "󰤨",
    "wifi_3": "󰤥",
    "wifi_2": "󰤢",
    "wifi_1": "󰤟",
    "bluetooth": "󰂯",
    "bluetooth_on": "󰂱",
    "shield": "󰒃",
    "bell_off": "󰂛",
    "coffee": "󰛊",
    "volume": "󰕾",
    "volume_mute": "󰝟",
    "mic": "󰍬",
    "mic_off": "󰍭",
    "sun": "󰃟",
    "moon": "󰽢",
    "palette": "󰏘",
    "settings": "󰒓",
    "lock": "󰌾",
    "power": "󰐥",
    "sleep": "󰒲",
    "leaf": "󰌪",
    "gauge": "󰂀",
    "zap": "󱐋",
    "globe": "󰖟",
    "key": "󰌆",
    "chevron_left": "‹",
    "chevron_right": "›",
    "headphones": "󰋋",
    "mouse": "󰍽",
    "keyboard": "󰌌",
    "laptop": "󰌢",
    "server": "󰒋",
    "phone": "󰏲",
    "monitor": "󰍹",
    "clock": "󰥔",
    "plus": "+",
    "play": "󰐊",
    "pause": "󰏤",
    "skip_back": "󰒮",
    "skip_forward": "󰒭",
    "live_dot": "●",
    "battery_charging": "󰂄",
    "music": "󰝚",
    "thermometer": "",  # U+F2C9, nf-fa-thermometer-2
}

# Discharging battery glyphs by 10% step (index 0 = empty … 10 = full).
BATTERY_LEVELS = (
    "󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹",
)
