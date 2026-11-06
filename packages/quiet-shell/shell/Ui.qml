pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland

// Which surfaces are open. One owner, so nothing can fight over visibility.
Singleton {
    id: root

    property string panel: ""            // "", controls, notifications, system, battery
    property string detail: ""           // "", wifi, bluetooth, vpn, sound, theme
    property bool spotlight: false
    property bool overview: false
    property bool topRevealed: false
    property bool dockRevealed: false
    property bool pinned: false
    property bool dragging: false
    property var confirm: null           // { title, body, action, command }
    property var hud: null               // { kind, level, muted }
    property bool switcher: false
    property int switcherIndex: 0

    // Hyprland sends no focus event when the focused monitor is unplugged, so it can
    // name a screen that's gone. Then every remaining screen counts, or nothing shows.
    readonly property string focusedScreen: {
        const m = Hyprland.focusedMonitor;
        return m && Quickshell.screens.some(s => s.name === m.name) ? m.name : "";
    }
    readonly property bool topShown: topRevealed || pinned || panel !== ""
    readonly property bool blocking: panel !== "" || spotlight || overview || confirm !== null || switcher

    // A focused field can disappear, which would leave the keyboard with nowhere to go.
    signal refocus
    onPanelChanged: refocus()
    onDetailChanged: refocus()

    property string spotlightQuery: ""

    // One path for these, so nothing can reach them without being asked.
    function session(name) {
        const lost = "Open apps will close, and anything unsaved will be lost.";
        const asks = {
            restart: { title: "Restart now?", body: lost, action: "Restart", command: ["systemctl", "reboot"] },
            shutdown: { title: "Shut down now?", body: lost, action: "Shut Down", command: ["systemctl", "poweroff"] },
            logout: { title: "Log out now?", body: lost, action: "Log Out", command: ["hyprctl", "dispatch", "hl.dsp.exit()"] }
        };
        close();
        if (name === "sleep") Quickshell.execDetached(["systemctl", "suspend"]);
        else if (name === "lock") Quickshell.execDetached(["hyprlock"]);
        else confirm = asks[name];
    }

    function showHud(kind, level, muted) {
        hud = { kind, level, muted };
        hudTimer.restart();
    }
    Timer { id: hudTimer; interval: 1400; onTriggered: root.hud = null }

    // Repeated presses arrive here too, because Hyprland's bind wins over the panel.
    function stepSwitcher(by) {
        const count = Dockable.recentWindows.length;
        if (count < 2)
            return;
        if (!switcher) {
            close();
            switcherIndex = by > 0 ? 1 : count - 1;
            switcher = true;
        } else {
            switcherIndex = (switcherIndex + by + count) % count;
        }
    }
    function commitSwitcher() {
        if (!switcher)
            return;
        const target = Dockable.recentWindows[switcherIndex];
        switcher = false;
        if (target)
            Dockable.revealAfterClose(target);
    }

    function close() {
        confirm = null;
        switcher = false;
        panel = "";
        detail = "";
        spotlight = false;
        overview = false;
        topRevealed = false;
    }
    function open(name) {
        spotlight = false;
        overview = false;
        detail = "";
        panel = panel === name ? "" : name;
        if (panel === "")
            topRevealed = false;
    }
    function toggleSpotlight() {
        const want = !spotlight;
        close();
        spotlightQuery = "";
        spotlight = want;
    }
    function openClipboard() {
        close();
        spotlightQuery = "cb ";
        spotlight = true;
    }
    function toggleOverview() {
        const want = !overview;
        close();
        overview = want;
    }
    function back() {
        if (detail === "mullvad")
            detail = "vpn";
        else if (detail !== "")
            detail = "";
        else
            close();
    }
}
