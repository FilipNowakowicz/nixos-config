//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.SystemTray

ShellRoot {
    id: root

    IpcHandler {
        target: "shell"
        function controls(): void { Ui.open("controls"); }
        function notifications(): void { Ui.open("notifications"); }
        function spotlight(): void { Ui.toggleSpotlight(); }
        function overview(): void { Ui.toggleOverview(); }
        function pin(): void { Ui.pinned = !Ui.pinned; }
        function close(): void { Ui.close(); }
        function reloadTheme(): void { Theme.reload(); }
        function state(): string {
            return JSON.stringify({ panel: Ui.panel, detail: Ui.detail, spotlight: Ui.spotlight, overview: Ui.overview, top: Ui.topShown, dock: Ui.dockRevealed, writes: Object.keys(Sys.writes), failed: Sys.failedCount, theme: Theme.name, notices: Notify.items.length, banner: !!Notify.banner, focus: Sys.focusMode, apps: Dockable.apps.map(a => ({ name: a.name, windows: a.windows.length, hidden: a.windows.filter(Dockable.isHidden).length })), suggested: Dockable.suggested.map(a => a.icon), tray: SystemTray.items.values.map(i => i.id), screen: Ui.focusedScreen, sys: Sys.state });
        }
    }

    // Focus moves around while monitors come and go, and the events can leave the shell
    // on the wrong screen. Read the settled answer from Hyprland afterwards.
    Connections {
        target: Quickshell
        function onScreensChanged() { resync.restart(); }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name.startsWith("monitor"))
                resync.restart();
        }
    }
    Timer {
        id: resync
        interval: 400
        onTriggered: Hyprland.refreshMonitors()
    }

    Binding { target: Sys; property: "live"; value: Ui.blocking || Ui.topShown }

    Variants {
        model: Quickshell.screens
        ShellWindow {
            required property var modelData
            screen: modelData
        }
    }
}
