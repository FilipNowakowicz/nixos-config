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

    // Hyprland sends no focus event when the focused monitor is unplugged, so it can
    // name a screen that's gone. Then every remaining screen counts, or nothing shows.
    readonly property string focusedScreen: {
        const m = Hyprland.focusedMonitor;
        return m && Quickshell.screens.some(s => s.name === m.name) ? m.name : "";
    }
    readonly property bool topShown: topRevealed || pinned || panel !== ""
    readonly property bool blocking: panel !== "" || spotlight || overview

    function close() {
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
        spotlight = want;
    }
    function toggleOverview() {
        const want = !overview;
        close();
        overview = want;
    }
    function back() {
        if (detail !== "")
            detail = "";
        else
            close();
    }
}
