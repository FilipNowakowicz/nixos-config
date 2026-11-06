import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// Live window thumbnails come from Quickshell's own capture, so no compositor plugin.
Item {
    id: root

    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.34) }

    readonly property var workspaces: Hyprland.workspaces.values.filter(w => w.id > 0).sort((a, b) => a.id - b.id)
    readonly property var windows: {
        const ws = Hyprland.focusedWorkspace;
        return ws ? ws.toplevels.values.filter(t => t.wayland) : [];
    }

    Row {
        x: 48
        y: 24
        spacing: 14
        Repeater {
            model: root.workspaces
            Press {
                id: desk
                required property var modelData
                readonly property bool active: Hyprland.focusedWorkspace === modelData
                width: 170
                height: 112
                radius: 12
                name: "Desktop " + modelData.id
                rest: "transparent"
                onClicked: Hyprland.dispatch("hl.dsp.focus({workspace=" + modelData.id + "})")
                Glass { width: 170; height: 96; radius: 11; lit: !desk.active; tint: desk.active ? Theme.fillHover : Theme.glass }
                Label { anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; text: "Desktop " + desk.modelData.id; font.pixelSize: 11 }
                Label { x: 0; y: 0; width: 170; height: 96; horizontalAlignment: Text.AlignHCenter; text: desk.modelData.toplevels.values.length + (desk.modelData.toplevels.values.length === 1 ? " window" : " windows"); font.pixelSize: 12; color: Theme.dim }
            }
        }
    }

    Label {
        anchors.right: side.left
        anchors.rightMargin: 24
        y: 28
        text: Qt.formatTime(clock.date, "HH:mm")
        font.pixelSize: 40
        font.weight: Font.Medium
    }
    SystemClock { id: clock; precision: SystemClock.Minutes }

    GridLayout {
        id: grid
        x: 48
        y: 170
        width: parent.width - 48 - side.width - 72
        height: parent.height - 170 - 104
        columns: Math.max(1, Math.ceil(Math.sqrt(root.windows.length)))
        rowSpacing: 18
        columnSpacing: 18
        Repeater {
            model: root.windows
            Press {
                id: tile
                required property var modelData
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 12
                name: modelData.title
                rest: "transparent"
                onClicked: { modelData.wayland.activate(); Ui.close(); }
                // Always there underneath, so a failed capture still leaves a usable tile.
                Glass { anchors.fill: parent; radius: 12 }
                AppIcon {
                    anchors.centerIn: parent
                    size: 72
                    icon: DesktopEntries.heuristicLookup(tile.modelData.wayland.appId)?.icon ?? ""
                    fallback: tile.modelData.wayland.appId || "?"
                }
                ScreencopyView {
                    anchors.fill: parent
                    anchors.margins: 4
                    captureSource: tile.modelData.wayland
                    live: true
                    constraintSize: Qt.size(Math.max(width, 1), Math.max(height, 1))
                }
                Label { anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 8; text: tile.modelData.title; font.pixelSize: 12 }
            }
        }
    }

    Column {
        id: side
        anchors.right: parent.right
        anchors.rightMargin: 24
        y: 24
        width: 340
        spacing: 12
        ControlCentre { width: 340 }
        NotificationCentre { compact: true; visible: Ui.detail === "" }
    }
}
