import QtQuick
import QtQuick.Layouts

// Spotlight's timers, at the top centre where the bar leaves a gap. A running timer
// is a small countdown pill that opens the list; one that has gone off grows into a
// card that stays until Stop or +5 min, or until the ring gives up by itself.
// Alarms set for later join the pill only in their last hour, so an alarm for the
// morning doesn't sit on screen all evening.
Item {
    id: root
    property bool quiet: false   // A fullscreen app: only a ring may show.
    property real now: Date.now()
    readonly property var ring: Sys.ringing.length ? Sys.ringing[0] : null
    readonly property var upcoming: Sys.timers.filter(t => t.kind === "Timer" || t.at - now < 3600000)
    readonly property bool active: ring !== null || (upcoming.length > 0 && !quiet)

    implicitWidth: ring ? 340 : pill.implicitWidth
    implicitHeight: ring ? card.implicitHeight : 30
    opacity: active ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.motion } }
    Behavior on implicitWidth { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
    Behavior on implicitHeight { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }

    Timer {
        running: root.active
        repeat: true
        interval: 1000
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    Glass { anchors.fill: parent; radius: root.ring ? 22 : 15 }

    Press {
        id: pill
        visible: !root.ring
        anchors.fill: parent
        radius: 15
        name: "Timers"
        implicitWidth: pillRow.implicitWidth + 22
        onClicked: Ui.openSpotlight("timers")
        RowLayout {
            id: pillRow
            anchors.centerIn: parent
            spacing: 6
            Icon { name: root.upcoming.length && root.upcoming[0].kind === "Alarm" ? "alarm-clock" : "timer"; size: 14 }
            Label {
                text: root.upcoming.length ? Sys.countdown(root.upcoming[0].at, root.now) : ""
                font.features: { "tnum": 1 }
                font.weight: Font.Medium
            }
            Label {
                visible: root.upcoming.length > 1
                text: "+" + (root.upcoming.length - 1)
                font.pixelSize: 12
                color: Theme.dim
            }
        }
    }

    ColumnLayout {
        id: card
        visible: root.ring !== null
        x: 14
        width: parent.width - 28
        spacing: 10
        Item { implicitHeight: 4 }
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Icon {
                id: bell
                name: "alarm-clock"
                size: 26
                // A small shake while it rings, the way a clock would.
                SequentialAnimation on rotation {
                    running: root.ring !== null && !Theme.reducedMotion
                    loops: Animation.Infinite
                    NumberAnimation { to: 12; duration: 70 }
                    NumberAnimation { to: -12; duration: 140 }
                    NumberAnimation { to: 8; duration: 120 }
                    NumberAnimation { to: 0; duration: 90 }
                    PauseAnimation { duration: 900 }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Label {
                    Layout.fillWidth: true
                    text: root.ring ? (root.ring.kind === "Alarm" ? "Alarm" : "Timer done") + " · " + Qt.formatTime(new Date(root.ring.at), "HH:mm") : ""
                    font.pixelSize: 12
                    color: Theme.dim
                }
                Label {
                    Layout.fillWidth: true
                    text: root.ring ? root.ring.label : ""
                    font.pixelSize: 15
                    font.weight: Font.Medium
                }
            }
            Label {
                visible: Sys.ringing.length > 1
                text: "+" + (Sys.ringing.length - 1)
                font.pixelSize: 12
                color: Theme.dim
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Press {
                Layout.fillWidth: true
                implicitHeight: 32
                radius: 16
                rest: Theme.fill
                name: "Snooze for 5 minutes"
                onClicked: Sys.snooze(root.ring)
                Label { anchors.centerIn: parent; text: "+5 min" }
            }
            Press {
                Layout.fillWidth: true
                implicitHeight: 32
                radius: 16
                rest: Theme.on
                hover: Theme.on
                name: "Stop"
                onClicked: Sys.stopRinging(root.ring.unit)
                Label { anchors.centerIn: parent; text: "Stop"; color: Theme.onText; font.weight: Font.Medium }
            }
        }
        Item { implicitHeight: 4 }
    }
}
