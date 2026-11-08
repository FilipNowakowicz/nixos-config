import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import Quickshell.Wayland

// Capsules. Clear on an empty desktop, glass as soon as a window could sit behind them.
Item {
    id: root
    readonly property bool clear: {
        const ws = Hyprland.focusedWorkspace;
        return !!ws && ws.toplevels.values.length === 0;
    }
    readonly property alias leftCapsule: left
    readonly property alias rightCapsule: right
    readonly property bool hovered: leftHover.hovered || rightHover.hovered

    property var hoveredDesk: null
    property real hoveredX: 0
    function showMenu(item) {
        const at = item.mapToItem(null, 0, item.height + 8);
        item.modelData.display(QsWindow.window, at.x, at.y);
    }
    function clock(format) { void Sys.zoneVersion; return Qt.formatDateTime(time.date, format); }

    SystemClock { id: time; precision: SystemClock.Minutes }

    Item {
        id: left
        y: 6
        x: 8
        height: 30
        width: leftRow.implicitWidth + 16
        opacity: Ui.topShown ? 1 : 0
        transform: Translate { y: Ui.topShown ? 0 : -38; Behavior on y { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } } }
        Behavior on opacity { NumberAnimation { duration: Theme.motion } }
        HoverHandler { id: leftHover }

        Glass { anchors.fill: parent; radius: 15; opacity: root.clear ? 0 : 1; Behavior on opacity { NumberAnimation { duration: Theme.motion } } }
        RowLayout {
            id: leftRow
            anchors.centerIn: parent
            spacing: 8
            Press {
                name: "System menu"
                implicitWidth: 24
                implicitHeight: 24
                radius: 12
                toggled: Ui.panel === "system"
                onClicked: Ui.open("system")
                Icon { anchors.centerIn: parent; name: "nixos"; size: 16 }
            }
            Label {
                text: {
                    const t = ToplevelManager.activeToplevel;
                    return t && t.appId ? Dockable.nameOf(t.appId) : "Desktop";
                }
                font.weight: Font.DemiBold
            }
            Row {
                spacing: 0
                Repeater {
                    model: Dockable.desks
                    Press {
                        id: dot
                        required property var modelData
                        required property int index
                        readonly property bool active: !!Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                        readonly property bool occupied: modelData.apps.length > 0
                        name: "Desktop " + modelData.id
                        width: index === 4 ? 21 : 15
                        height: 22
                        radius: 7
                        rest: "transparent"
                        hover: "transparent"
                        onHoveredChanged: {
                            if (hovered) {
                                root.hoveredDesk = modelData;
                                root.hoveredX = dot.mapToItem(root, 7, 0).x;
                            } else if (root.hoveredDesk && root.hoveredDesk.id === modelData.id) {
                                root.hoveredDesk = null;
                            }
                        }
                        onClicked: Hyprland.dispatch("hl.dsp.focus({workspace=" + modelData.id + "})")
                        // The wider fifth slot splits the row in two, so dots can be counted.
                        Rectangle {
                            x: 7.5 - width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: dot.active ? 9 : dot.occupied ? 7 : 5
                            height: width
                            radius: width / 2
                            color: dot.active ? Theme.text : dot.occupied ? Theme.dim : "transparent"
                            border.width: dot.active || dot.occupied ? 0 : 1
                            border.color: Theme.faint
                        }
                    }
                }
            }
        }
    }

    // Says what's on a desktop without going there.
    Item {
        visible: root.hoveredDesk !== null && Ui.topShown
        x: Math.max(8, root.hoveredX - width / 2)
        y: 42
        width: tip.implicitWidth + 20
        height: 28
        Glass { anchors.fill: parent; radius: 14 }
        Label {
            id: tip
            anchors.centerIn: parent
            font.pixelSize: 12
            text: {
                const d = root.hoveredDesk;
                if (!d) return "";
                return d.id + "  " + (d.apps.length ? d.apps.join(", ") : "Empty");
            }
        }
    }

    Item {
        id: right
        y: 6
        anchors.right: parent.right
        anchors.rightMargin: 8
        height: 30
        width: rightRow.implicitWidth + 12
        opacity: Ui.topShown ? 1 : 0
        transform: Translate { y: Ui.topShown ? 0 : -38; Behavior on y { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } } }
        Behavior on opacity { NumberAnimation { duration: Theme.motion } }
        HoverHandler { id: rightHover }

        Glass { anchors.fill: parent; radius: 15; opacity: root.clear ? 0 : 1; Behavior on opacity { NumberAnimation { duration: Theme.motion } } }
        RowLayout {
            id: rightRow
            anchors.centerIn: parent
            spacing: 2

            Row {
                spacing: 8
                leftPadding: 5
                rightPadding: 4
                Layout.alignment: Qt.AlignVCenter
                Press {
                    visible: Sys.failedCount > 0
                    name: "Show failed settings"
                    width: 18
                    height: 18
                    radius: 9
                    onClicked: Ui.open("controls")
                    Icon { anchors.centerIn: parent; name: "triangle-alert"; size: 15 }
                }
                // Nothing here unless an app asks for it.
                Repeater {
                    model: SystemTray.items
                    Press {
                        id: trayItem
                        required property var modelData
                        width: 18
                        height: 18
                        radius: 5
                        name: modelData.tooltipTitle || modelData.title || modelData.id
                        onClicked: modelData.onlyMenu ? root.showMenu(trayItem) : modelData.activate()
                        onSecondaryClicked: modelData.hasMenu ? root.showMenu(trayItem) : modelData.secondaryActivate()
                        // Grey like the dock's app icons, with colour while pointed at.
                        property real grey: Theme.monoIcons && !hovered && !activeFocus ? 1 : 0
                        Behavior on grey { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
                        Image {
                            anchors.fill: parent
                            source: trayItem.modelData.icon
                            sourceSize: Qt.size(36, 36)
                            opacity: 1 - 0.12 * trayItem.grey
                            layer.enabled: trayItem.grey > 0
                            layer.effect: MultiEffect { saturation: -trayItem.grey }
                        }
                    }
                }
                Icon { visible: Sys.focusMode; name: "bell-off"; size: 15 }
                Icon { visible: Sys.awake; name: "coffee"; size: 15 }
                Icon { visible: Sys.muted; name: "volume-x"; size: 15 }
                Icon { visible: Sys.wifiOn; name: "wifi"; size: 15 }
            }
            Press {
                visible: Sys.battery !== null
                name: "Battery"
                implicitHeight: 24
                implicitWidth: batteryRow.implicitWidth + 14
                radius: 12
                toggled: Ui.panel === "battery"
                onClicked: Ui.open("battery")
                Row {
                    id: batteryRow
                    anchors.centerIn: parent
                    spacing: 5
                    Icon { anchors.verticalCenter: parent.verticalCenter; name: Sys.battery && Sys.battery.charging ? "battery-charging" : "battery-medium"; size: 15 }
                    Label { text: Sys.battery ? Sys.battery.level + "%" : ""; font.features: { "tnum": 1 } }
                }
            }
            Press {
                name: "Control centre"
                implicitWidth: 28
                implicitHeight: 24
                radius: 12
                toggled: Ui.panel === "controls"
                onClicked: Ui.open("controls")
                Icon { anchors.centerIn: parent; name: "sliders-horizontal"; size: 15 }
            }
            Press {
                name: "Calendar and notifications"
                implicitHeight: 24
                implicitWidth: clockText.implicitWidth + 14
                radius: 12
                toggled: Ui.panel === "notifications"
                onClicked: Ui.open("notifications")
                Label { id: clockText; anchors.centerIn: parent; text: root.clock("ddd d MMM  HH:mm"); font.features: { "tnum": 1 } }
            }
        }
    }
}
