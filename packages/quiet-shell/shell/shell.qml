//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Polkit
import Quickshell.Services.SystemTray

ShellRoot {
    id: root

    IpcHandler {
        target: "shell"
        function controls(): void { Ui.open("controls"); }
        function notifications(): void { Ui.open("notifications"); }
        function spotlight(): void { Ui.toggleSpotlight(); }
        function overview(): void { Ui.toggleOverview(); }
        function volume(step: int): void { Sys.nudgeVolume(step); }
        function mute(): void { Sys.nudgeMute(); }
        function brightness(step: int): void { Sys.nudgeBrightness(step); }
        function switcher(step: int): void { Ui.stepSwitcher(step); }
        function switcherDone(): void { Ui.commitSwitcher(); }
        function clipboard(): void { Ui.openClipboard(); }
        function screenshot(): void { Ui.toggleScreenshot(); }
        function shortcuts(): void { Ui.toggleCheatSheet(); }
        function pin(): void { Ui.pinned = !Ui.pinned; }
        function close(): void { Ui.close(); }
        function testAuth(): void { testAuth.active = true; }
        function reloadTheme(): void { Theme.reload(); }
        function state(): string {
            return JSON.stringify({ panel: Ui.panel, detail: Ui.detail, spotlight: Ui.spotlight, overview: Ui.overview, top: Ui.topShown, dock: Ui.dockRevealed, writes: Object.keys(Sys.writes), clipboard: Ui.clipboard, results: Ui.spotlightResults, joining: Sys.joining, auth: Ui.auth ? Ui.auth.message : "", authFailed: !!Ui.auth && Ui.auth.failed, failed: Sys.failedCount, theme: Theme.name, notices: Notify.items.length, banner: !!Notify.banner, focus: Sys.focusMode, deskHud: Ui.deskHud, screenshot: Ui.screenshot, cheatSheet: Ui.cheatSheet, shortcuts: Ui.shortcuts.reduce((all, column) => all.concat(column), []).filter(r => r.length > 1).map(r => r[0]), weather: Sys.weather, agenda: Sys.agenda, confirm: Ui.confirm ? Ui.confirm.action : "", hud: Ui.hud, switcher: Ui.switcher ? Ui.switcherIndex : -1, active: Hyprland.activeToplevel ? Hyprland.activeToplevel.title : "", recent: Dockable.recentWindows.map(t => t.address), apps: Dockable.apps.map(a => ({ name: a.name, windows: a.windows.length, hidden: a.windows.filter(Dockable.isHidden).length })), tray: SystemTray.items.values.map(i => i.id), screen: Ui.focusedScreen, sys: Sys.state });
        }
    }

    // Focus moves around while monitors come and go, and the events can leave the shell
    // on the wrong screen. Read the settled answer from Hyprland afterwards.
    Connections {
        target: Quickshell
        function onScreensChanged() { resync.left = 2; resync.restart(); }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name.startsWith("monitor")) {
                resync.left = 2;
                resync.restart();
            }
        }
    }
    Timer {
        id: resync
        interval: 400
        property int left: 0
        onTriggered: {
            Hyprland.refreshMonitors();
            if (left-- > 0)
                restart();
        }
    }

    Binding { target: Sys; property: "live"; value: Ui.blocking || Ui.topShown }

    // Both ends of SUPER+Tab arrive here in order. As separate processes, a quick tap's
    // release could overtake its press and leave the switcher open.
    GlobalShortcut { appid: "quiet-shell"; name: "switcher"; onPressed: Ui.stepSwitcher(1) }
    GlobalShortcut { appid: "quiet-shell"; name: "switcher-back"; onPressed: Ui.stepSwitcher(-1) }
    GlobalShortcut {
        appid: "quiet-shell"
        name: "switcher-done"
        onPressed: Ui.commitSwitcher()
        onReleased: Ui.commitSwitcher()
    }
    // The switcher leaves the keyboard with Hyprland, so Escape arrives this way.
    GlobalShortcut { appid: "quiet-shell"; name: "switcher-cancel"; onPressed: Ui.switcher = false }

    // Asks for passwords on behalf of apps. Tests load a stand-in, because polkit needs the system bus.
    PolkitAgent { id: polkit }
    Loader { id: testAuth; active: false; source: Quickshell.env("QUIET_TEST_AUTH") ?? "" }
    Connections {
        target: testAuth.item
        function onClosed() { testAuth.active = false; }
    }
    Binding {
        target: Ui
        property: "auth"
        value: testAuth.item ?? (polkit.flow && !polkit.flow.isCompleted ? polkit.flow : null)
    }

    Variants {
        model: Quickshell.screens
        ShellWindow {
            required property var modelData
            screen: modelData
        }
    }
}
