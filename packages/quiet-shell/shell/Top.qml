import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
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

    function occupied() {
        const out = [];
        const focused = Hyprland.focusedWorkspace;
        for (const ws of Hyprland.workspaces.values) {
            if (ws.id > 0 && (ws.toplevels.values.length > 0 || ws === focused))
                out.push(ws.id);
        }
        return out.sort((a, b) => a - b);
    }
    function clock(format) { return Qt.formatDateTime(time.date, format); }

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
                Icon { anchors.centerIn: parent; name: "snowflake"; size: 15 }
            }
            Label {
                text: {
                    const t = ToplevelManager.activeToplevel;
                    const id = t ? t.appId : "";
                    return id ? id.charAt(0).toUpperCase() + id.slice(1) : "Desktop";
                }
                font.weight: Font.DemiBold
            }
            Row {
                spacing: 0
                Repeater {
                    model: root.occupied()
                    Press {
                        required property int modelData
                        readonly property bool active: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData
                        name: "Desktop " + modelData
                        width: 15
                        height: 22
                        radius: 7
                        onClicked: Hyprland.dispatch("hl.dsp.focus({workspace=" + modelData + "})")
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.active ? 7 : 5
                            height: width
                            radius: width / 2
                            color: parent.active ? Theme.text : Theme.faint
                        }
                    }
                }
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
                Icon { visible: Sys.focusMode; name: "bell-off"; size: 15 }
                Icon { visible: Sys.awake; name: "coffee"; size: 15 }
                Icon { visible: Sys.night; name: "moon"; size: 15 }
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
