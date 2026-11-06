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
    property var themes: []

    readonly property real glassAlpha: 0.42
    readonly property color glass: Qt.rgba(bg.r, bg.g, bg.b, glassAlpha)
    readonly property color hairline: Qt.rgba(text.r, text.g, text.b, 0.15)
    readonly property color litEdge: Qt.rgba(text.r, text.g, text.b, 0.34)
    readonly property color fill: Qt.rgba(text.r, text.g, text.b, 0.12)
    readonly property color fillHover: Qt.rgba(text.r, text.g, text.b, 0.2)
    readonly property color track: Qt.rgba(text.r, text.g, text.b, 0.22)
    readonly property color dim: Qt.rgba(text.r, text.g, text.b, 0.66)
    readonly property color faint: Qt.rgba(text.r, text.g, text.b, 0.42)
    readonly property color on: text
    readonly property color onText: bg

    readonly property string font: "Open Runde"
    readonly property int motion: reducedMotion ? 0 : 190
    readonly property bool reducedMotion: Quickshell.env("QUIET_REDUCED_MOTION") === "1"

    readonly property string colorsPath: Quickshell.env("QUIET_COLORS")
        || (Quickshell.env("HOME") + "/.config/quiet-shell/colors.json")

    FontLoader { source: Qt.resolvedUrl("assets/fonts/OpenRunde-Regular.woff2") }
    FontLoader { source: Qt.resolvedUrl("assets/fonts/OpenRunde-Medium.woff2") }
    FontLoader { source: Qt.resolvedUrl("assets/fonts/OpenRunde-Semibold.woff2") }

    FileView {
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
                root.themes = c.themes || root.themes;
            } catch (e) {
                console.warn("quiet-shell: bad colours file", e);
            }
        }
    }
}
