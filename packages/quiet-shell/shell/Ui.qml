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
    property var auth: null              // polkit's request for a password
    onAuthChanged: refocus()
    property var hud: null               // { kind, level, muted } or { kind, on, toggle }
    property var dockMenu: null          // { app, x }
    property int deskHud: 0
    Timer { id: deskTimer; interval: 900; onTriggered: root.deskHud = 0 }
    Connections {
        target: Hyprland
        function onFocusedWorkspaceChanged() {
            const ws = Hyprland.focusedWorkspace;
            // Startup isn't a change, and the bar or overview already shows it.
            if (ws && ws.id > 0 && root.deskSeen && !root.topShown && !root.overview) {
                root.deskHud = ws.id;
                deskTimer.restart();
            }
            root.deskSeen = true;
        }
    }
    property bool deskSeen: false
    property bool screenshot: false
    property bool cheatSheet: false
    // Each list is a column. A one-item row is a heading.
    readonly property var shortcuts: [
        [
            ["Windows"],
            ["SUPER + Return", "Terminal"],
            ["SUPER + b", "Browser"],
            ["SUPER + apostrophe", "Close window"],
            ["SUPER + minus", "Minimise window"],
            ["SUPER + T", "Float window"],
            ["SUPER + F", "Maximise"],
            ["SUPER + SHIFT + F", "Fullscreen"],
            ["SUPER + D", "Desktop mode: float all"],
            ["SUPER + M", "Change layout"],
            ["SUPER + Tab", "Switch window"],
            ["SUPER + h", "Focus left"],
            ["SUPER + l", "Focus right"],
            ["Desktops"],
            ["SUPER + 1", "Go to desktop 1"],
            ["SUPER + SHIFT + 1", "Move window to desktop 1"]
        ],
        [
            ["Shell"],
            ["SUPER + Space", "Spotlight"],
            ["SUPER + c", "Control centre"],
            ["SUPER + n", "Notifications"],
            ["SUPER + o", "Overview"],
            ["SUPER + V", "Clipboard history"],
            ["SUPER + W", "Keep the bar open"],
            ["SUPER + slash", "Shortcuts"],
            ["SUPER + SHIFT + n", "Notes"],
            ["Capture"],
            ["SUPER + SHIFT + s", "Screenshot or copy text"],
            ["System"],
            ["SUPER + Escape", "Power menu"],
            ["SUPER + BackSpace", "Lock"]
        ]
    ]
    property bool switcher: false
    property int switcherIndex: 0

    // Hyprland sends no focus event when the focused monitor is unplugged, so it can
    // name a screen that's gone. Then every remaining screen counts, or nothing shows.
    // Quickshell can also lose its answer if a refresh overlaps a new monitor, so the
    // last focus event, which arrives in order, comes first.
    property string lastFocusEvent: ""
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "focusedmon")
                root.lastFocusEvent = event.data.split(",")[0];
            else if (event.name === "monitorremoved" && event.data === root.lastFocusEvent)
                root.lastFocusEvent = "";
        }
    }
    readonly property string focusedScreen: {
        const m = Hyprland.focusedMonitor;
        const candidates = [lastFocusEvent, m ? m.name : ""];
        return candidates.find(name => Quickshell.screens.some(s => s.name === name)) ?? "";
    }
    readonly property bool topShown: topRevealed || pinned || panel !== ""
    readonly property bool blocking: panel !== "" || spotlight || overview || confirm !== null || switcher || screenshot || cheatSheet || auth !== null

    // A focused field can disappear, which would leave the keyboard with nowhere to go.
    signal refocus
    onPanelChanged: refocus()
    onDetailChanged: refocus()

    property bool clipboard: false       // Spotlight is showing clipboard history
    property var spotlightResults: []    // "Group: Title" of each row, for tests
    property string spotlightQuery: ""   // what is typed, for tests

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
    // A switch flipped by its own key, such as mic mute: an icon and a word, no level.
    function showToggle(kind, on) {
        hud = { kind, on, toggle: true };
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

    function openDockMenu(app, x) {
        close();
        dockMenu = { app, x };
        panel = "dock";
    }

    function toggleScreenshot() {
        const want = !screenshot;
        close();
        screenshot = want;
    }
    function toggleCheatSheet() {
        const want = !cheatSheet;
        close();
        cheatSheet = want;
    }

    function close() {
        confirm = null;
        screenshot = false;
        cheatSheet = false;
        dockMenu = null;
        switcher = false;
        panel = "";
        detail = "";
        spotlight = false;
        clipboard = false;
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
        spotlight = want;
    }
    function openClipboard() {
        close();
        clipboard = true;
        spotlight = true;
    }
    function toggleOverview() {
        const want = !overview;
        close();
        overview = want;
    }
    function back() {
        if (auth)
            auth.cancelAuthenticationRequest();
        else if (detail === "mullvad")
            detail = "vpn";
        else if (detail !== "")
            detail = "";
        else
            close();
    }
}
