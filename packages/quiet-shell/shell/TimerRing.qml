import QtQuick
import QtQuick.Layouts

// A timer or alarm that has gone off: a card at the top centre that stays until
// Stop or Restart (Snooze for an alarm), or until the ring gives up by itself.
// SUPER+x and SUPER+r do the same from anywhere. Running timers live in the bar.
Item {
    id: root
    readonly property var ringing: Sys.ringing.length ? Sys.ringing[0] : null
    // What the card shows. It keeps the last ring while the card fades out, so
    // the words don't change to a fallback on the way.
    property var ring: null
    onRingingChanged: if (ringing) ring = ringing
    readonly property bool alarm: !!ring && ring.kind === "Alarm"
    readonly property bool restarts: !!ring && !alarm && ring.seconds > 0

    implicitWidth: 340
    implicitHeight: card.implicitHeight
    opacity: ringing ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.motion } }

    Glass { anchors.fill: parent; radius: 22 }

    ColumnLayout {
        id: card
        x: 14
        width: parent.width - 28
        spacing: 10
        Item { implicitHeight: 4 }
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Icon {
                name: "alarm-clock"
                size: 26
                // A small shake while it rings, the way a clock would.
                SequentialAnimation on rotation {
                    running: root.ringing !== null && !Theme.reducedMotion
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
                    text: root.ring ? (root.alarm ? "Alarm · " : "Timer done · ") + Qt.formatTime(new Date(root.ring.at), "HH:mm") : ""
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
                implicitHeight: 38
                radius: 19
                rest: Theme.fill
                name: root.restarts ? "Restart" : "Snooze"
                onClicked: if (root.ringing) Sys.restartRinging(root.ringing)
                Label { anchors.centerIn: parent; text: root.restarts ? "Restart" : "Snooze" }
                SuperHint { anchors.right: parent.right; anchors.rightMargin: 13; anchors.top: parent.top; anchors.topMargin: 6; key: "R" }
            }
            Press {
                Layout.fillWidth: true
                implicitHeight: 38
                radius: 19
                rest: Theme.on
                hover: Theme.on
                name: "Stop"
                onClicked: if (root.ringing) Sys.stopRinging(root.ringing.unit)
                Label { anchors.centerIn: parent; text: "Stop"; color: Theme.onText; font.weight: Font.Medium }
                SuperHint { anchors.right: parent.right; anchors.rightMargin: 13; anchors.top: parent.top; anchors.topMargin: 6; key: "X"; tint: Theme.onText }
            }
        }
        Item { implicitHeight: 4 }
    }
}
