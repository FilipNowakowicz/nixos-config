import QtQuick
import QtQuick.Layouts

// The mouse's battery, on one line under the phone. status.py asks the mouse over
// HID++; while it sleeps the last reading stays, dimmed. No receiver, no card.
Item {
    id: root
    readonly property var mouse: Sys.mouse
    readonly property bool low: !!mouse && mouse.level <= 15
    visible: mouse !== null
    implicitHeight: 36

    Glass { anchors.fill: parent; radius: 18 }
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 8
        Icon { name: "mouse"; size: 14; color: root.mouse && root.mouse.awake ? Theme.text : Theme.faint }
        Label {
            Layout.fillWidth: true
            text: "Mouse"
            font.pixelSize: 12
            font.weight: Font.Medium
            color: root.mouse && root.mouse.awake ? Theme.text : Theme.dim
        }
        Label {
            visible: !!root.mouse && !root.mouse.awake
            text: "Asleep"
            font.pixelSize: 10
            color: Theme.faint
        }
        Icon { name: "battery-medium"; size: 14; color: root.low ? Theme.text : Theme.dim }
        Label {
            text: root.mouse ? root.mouse.level + "%" : ""
            font.pixelSize: 10
            font.features: { "tnum": 1 }
            color: root.low ? Theme.text : Theme.dim
        }
    }
}
