pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Colours come from the repo's theme system, as colors.json. Everything else is
// derived from them, so a theme switch restyles the whole shell.
Singleton {
    id: root

    property color bg: "#0a0a0a"
    property color accent: "#cccccc"
    property color text: "#e8e8e8"
    property string name: "mono-mesh"
    // A light theme draws dark text on pale glass; a few derived colours flip.
    property bool light: false
    property var themes: []
    property string themesSource: ""

    // App icons stay grey until pointed at, chosen or focused. Kept across restarts.
    property bool monoIcons: true
    onMonoIconsChanged: if (iconsFile.loaded) iconsFile.setText(monoIcons ? "mono" : "colour")

    readonly property real glassAlpha: light ? 0.5 : 0.42
    // Light glass is lifted a little toward white, enough to separate pills from a
    // pale wallpaper without glaring.
    readonly property color glassBase: light ? Qt.tint(bg, Qt.rgba(1, 1, 1, 0.15)) : bg
    readonly property color glass: Qt.rgba(glassBase.r, glassBase.g, glassBase.b, glassAlpha)
    readonly property color hairline: Qt.rgba(text.r, text.g, text.b, 0.15)
    readonly property color litEdge: light ? Qt.rgba(1, 1, 1, 0.45) : Qt.rgba(text.r, text.g, text.b, 0.34)
    readonly property color fill: Qt.rgba(text.r, text.g, text.b, 0.12)
    readonly property color fillHover: Qt.rgba(text.r, text.g, text.b, 0.2)
    readonly property color track: Qt.rgba(text.r, text.g, text.b, 0.22)
    readonly property color dim: Qt.rgba(text.r, text.g, text.b, 0.66)
    readonly property color faint: Qt.rgba(text.r, text.g, text.b, 0.42)
    // What is switched on. Dark themes light it up in the text colour; on paper a
    // dark disc reads as inverted, so light themes use the accent.
    readonly property color on: light ? accent : text
    readonly property color onText: bg

    readonly property string font: "Open Runde"
    readonly property int motion: reducedMotion ? 0 : 190
    readonly property bool reducedMotion: Quickshell.env("QUIET_REDUCED_MOTION") === "1"

    readonly property string colorsPath: Quickshell.env("QUIET_COLORS")
        || (Quickshell.env("HOME") + "/.config/quiet-shell/colors.json")

    FontLoader { source: Qt.resolvedUrl("assets/fonts/OpenRunde-Regular.woff2") }
    FontLoader { source: Qt.resolvedUrl("assets/fonts/OpenRunde-Medium.woff2") }
    FontLoader { source: Qt.resolvedUrl("assets/fonts/OpenRunde-Semibold.woff2") }

    // theme-switch replaces a symlink, which a file watcher only survives once, so
    // it also calls this. The watcher just covers edits made by hand.
    function reload() { colors.reload(); }

    // One picker tile. A plain name (an older colours file) still gets a tile, drawn
    // from this theme's colours with no picture.
    function pickerEntry(entry) {
        const t = typeof entry === "string" ? { name: entry } : entry;
        const hex = (v, fallback) => v ? "#" + v : fallback;
        return {
            name: t.name,
            title: t.title || t.name.split("-").map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(" "),
            bg: hex(t.bg, root.bg),
            surface: hex(t.surface, Qt.rgba(root.text.r, root.text.g, root.text.b, 0.12)),
            accent: hex(t.accent, root.accent),
            text: hex(t.text, root.text),
            thumbnail: t.thumbnail ? "file://" + t.thumbnail : ""
        };
    }

    FileView {
        id: iconsFile
        property bool loaded: false
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/quiet-shell/icons"
        printErrors: false
        onLoaded: { root.monoIcons = text().trim() !== "colour"; loaded = true; }
        onLoadFailed: loaded = true
    }

    FileView {
        id: colors
        path: root.colorsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const c = JSON.parse(text());
                root.bg = "#" + c.bg;
                root.accent = "#" + c.accent;
                root.text = "#" + c.text;
                root.name = c.name || root.name;
                root.light = c.appearance === "light";
                // Every theme lists the same picker entries; keep the old array (and the
                // tiles built from it) unless the list itself changed.
                const list = JSON.stringify(c.themes || null);
                if (c.themes && list !== root.themesSource) {
                    root.themesSource = list;
                    root.themes = c.themes.map(root.pickerEntry);
                }
            } catch (e) {
                console.warn("quiet-shell: bad colours file", e);
            }
        }
    }
}
