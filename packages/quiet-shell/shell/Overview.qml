import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// Live window thumbnails come from Quickshell's own capture, so no compositor plugin.
Item {
    id: root

    // Nearly solid: a see-through backdrop would show every window twice.
    Rectangle { anchors.fill: parent; color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.94) }

    // A capture ends for good when its window changes size, which every window sharing a
    // desktop does when one moves. So start them again once the layout has settled.
    property bool capturing: true
    Timer {
        id: recapture
        interval: 600
        onTriggered: { Hyprland.refreshToplevels(); root.capturing = false; Qt.callLater(() => root.capturing = true); }
    }
    // Positions come from Hyprland's client list, which is only read on request.
    Component.onCompleted: Hyprland.refreshToplevels()
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (["openwindow", "closewindow", "movewindow"].includes(event.name))
                recapture.restart();
        }
    }

    // The desktops in use, plus one empty one to drag a window onto. Leaving an empty
    // desktop deletes it, so counting it as used would let Tab walk through all ten.
    readonly property var desks: {
        const known = {};
        for (const ws of Hyprland.workspaces.values)
            if (ws.id > 0 && ws.id <= 10)
                known[ws.id] = ws;
        const focused = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0;
        const ids = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        const used = id => known[id] && (id !== focused || known[id].toplevels.values.length > 0);
        const empty = ids.find(id => !used(id));
        return ids
            .filter(id => used(id) || id === empty || id === focused)
            .map(id => ({ id, workspace: known[id] ?? null }));
    }
    // Stays on this screen: a desktop on another one would take the overview with it.
    function step(by) {
        const ids = desks.filter(d => !d.workspace || d.workspace.monitor === Hyprland.focusedMonitor).map(d => d.id);
        const at = ids.indexOf(Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0);
        Hyprland.dispatch("hl.dsp.focus({workspace=" + ids[(at + by + ids.length) % ids.length] + "})");
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
                width: root.deskWidth
                height: 112
                radius: 12
                name: "Desktop " + modelData.id
                rest: "transparent"
                onClicked: Hyprland.dispatch("hl.dsp.focus({workspace=" + modelData.id + "})")
                Glass { width: parent.width; height: 96; radius: 11; lit: !desk.active; tint: desk.active || drop.containsDrag ? Theme.fillHover : Theme.glass }
                // The desktop in miniature, each window where it really sits.
                Item {
                    id: mini
                    readonly property var monitor: desk.modelData.workspace ? desk.modelData.workspace.monitor : null
                    readonly property real fit: monitor ? Math.min(width * monitor.scale / monitor.width, height * monitor.scale / monitor.height) : 0
                    // Screens rarely match the tile's shape, so centre the leftover space.
                    readonly property real insetX: monitor ? (width - fit * monitor.width / monitor.scale) / 2 : 0
                    readonly property real insetY: monitor ? (height - fit * monitor.height / monitor.scale) / 2 : 0
                    x: 6
                    y: 6
                    width: parent.width - 12
                    height: 84
                    clip: true
                    Repeater {
                        model: desk.modelData.workspace ? desk.modelData.workspace.toplevels.values.filter(t => t.wayland && t.lastIpcObject.at) : []
                        Item {
                            id: miniWindow
                            required property var modelData
                            x: mini.monitor ? mini.insetX + (modelData.lastIpcObject.at[0] - mini.monitor.x) * mini.fit : 0
                            y: mini.monitor ? mini.insetY + (modelData.lastIpcObject.at[1] - mini.monitor.y) * mini.fit : 0
                            width: modelData.lastIpcObject.size[0] * mini.fit
                            height: modelData.lastIpcObject.size[1] * mini.fit
                            Loader {
                                anchors.fill: parent
                                active: root.capturing
                                sourceComponent: WindowPreview {
                                    toplevel: miniWindow.modelData.wayland
                                    appId: miniWindow.modelData.wayland.appId
                                    iconSize: 20
                                    captureSize: Qt.size(360, 220)
                                }
                            }
                        }
                    }
                }
                Rectangle {
                    width: parent.width
                    height: 96
                    radius: 11
                    color: "transparent"
                    visible: drop.containsDrag || desk.active
                    border.width: 2
                    border.color: Theme.accent
                }
                Label { anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; text: "Desktop " + desk.modelData.id; font.pixelSize: 11 }
                DropArea {
                    id: drop
                    anchors.fill: parent
                    onDropped: if (!desk.active) Dockable.move(ghost.window, desk.modelData.id, false)
                }
            }
        }
    }

    Column {
        anchors.right: side.left
        anchors.rightMargin: 24
        y: 28
        Label {
            anchors.right: parent.right
            text: Qt.formatTime(clock.date, "HH:mm")
            font.pixelSize: 40
            font.weight: Font.Medium
        }
        Label {
            anchors.right: parent.right
            text: Qt.formatDate(clock.date, "dddd d MMMM")
            color: Theme.dim
        }
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
