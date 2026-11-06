//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

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
        function state(): string {
            return JSON.stringify({ panel: Ui.panel, detail: Ui.detail, spotlight: Ui.spotlight, overview: Ui.overview, top: Ui.topShown, dock: Ui.dockRevealed, writes: Object.keys(Sys.writes), failed: Sys.failedCount, theme: Theme.name, notices: Notify.items.length, banner: !!Notify.banner, focus: Sys.focusMode, sys: Sys.state });
        }
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
