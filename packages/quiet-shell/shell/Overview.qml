import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// Live window thumbnails come from Quickshell's own capture, so no compositor plugin.
Item {
    id: root

    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.34) }

    // A capture ends for good when its window changes size, which every window sharing a
    // desktop does when one moves. So start them again once the layout has settled.
    property bool capturing: true
    Timer {
        id: recapture
        interval: 600
        onTriggered: { root.capturing = false; Qt.callLater(() => root.capturing = true); }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (["openwindow", "closewindow", "movewindow"].includes(event.name))
                recapture.restart();
        }
    }

    // The desktops in use, plus one empty one to drag a window onto.
    readonly property var desks: {
        const used = {};
        for (const ws of Hyprland.workspaces.values)
            if (ws.id > 0 && ws.id <= 10)
                used[ws.id] = ws;
        const empty = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].find(id => !used[id]);
        return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
            .filter(id => used[id] || id === empty)
            .map(id => ({ id, workspace: used[id] ?? null }));
    }
    readonly property int deskWidth: Math.min(170, (width - 48 - side.width - 200 - (desks.length - 1) * 14) / desks.length)
    readonly property var windows: {
        const ws = Hyprland.focusedWorkspace;
        return ws ? ws.toplevels.values.filter(t => t.wayland) : [];
    }

    Row {
        x: 48
        y: 24
        spacing: 14
        Repeater {
            model: root.desks
            Press {
                id: desk
                required property var modelData
                readonly property bool active: !!Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                readonly property int count: modelData.workspace ? modelData.workspace.toplevels.values.length : 0
                width: root.deskWidth
                height: 112
                radius: 12
                name: "Desktop " + modelData.id
                rest: "transparent"
                onClicked: Hyprland.dispatch("hl.dsp.focus({workspace=" + modelData.id + "})")
                Glass { width: parent.width; height: 96; radius: 11; lit: !desk.active; tint: desk.active || drop.containsDrag ? Theme.fillHover : Theme.glass }
                Rectangle {
                    width: parent.width
                    height: 96
                    radius: 11
                    color: "transparent"
                    visible: drop.containsDrag
                    border.width: 2
                    border.color: Theme.accent
                }
                Label { anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; text: "Desktop " + desk.modelData.id; font.pixelSize: 11 }
                Label { x: 0; y: 0; width: parent.width; height: 96; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; text: desk.count === 0 ? "Empty" : desk.count === 1 ? "1 window" : desk.count + " windows"; font.pixelSize: 12; color: Theme.dim }
                DropArea {
                    id: drop
                    anchors.fill: parent
                    onDropped: if (!desk.active) Dockable.move(ghost.window, desk.modelData.id, false)
                }
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
                opacity: dragging ? 0.3 : 1
                dragTarget: ghost
                onClicked: { Dockable.revealWayland(modelData.wayland); Ui.close(); }
                onPressedAt: (x, y) => {
                    const at = mapToItem(root, x, y);
                    ghost.x = at.x - ghost.width / 2;
                    ghost.y = at.y - ghost.height / 2;
                }
                onDraggingChanged: if (dragging) ghost.window = modelData
                onDropped: { ghost.Drag.drop(); ghost.window = null; }
                // Always there underneath, so a failed capture still leaves a usable tile.
                Glass { anchors.fill: parent; radius: 12 }
                Loader {
                    anchors.fill: parent
                    anchors.margins: 4
                    active: root.capturing
                    sourceComponent: WindowPreview {
                        toplevel: tile.modelData.wayland
                        appId: tile.modelData.wayland ? tile.modelData.wayland.appId : ""
                        iconSize: 72
                        captureSize: Qt.size(960, 600)
                    }
                }
                Label { anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 8; text: tile.modelData.title; font.pixelSize: 12 }
            }
        }
    }

    // What the pointer carries while a window is dragged onto a desktop.
    Item {
        id: ghost
        property var window: null
        visible: window !== null
        width: 220
        height: 140
        z: 5
        Drag.active: visible
        Drag.hotSpot: Qt.point(width / 2, height / 2)
        Glass { anchors.fill: parent; radius: 12 }
        ScreencopyView {
            anchors.fill: parent
            anchors.margins: 4
            captureSource: ghost.window ? ghost.window.wayland : null
            live: true
            constraintSize: Qt.size(440, 280)
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
