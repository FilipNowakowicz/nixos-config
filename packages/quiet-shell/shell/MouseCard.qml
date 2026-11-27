import QtQuick
import QtQuick.Layouts

// The mouse on one line above the phone: its name, DPI and battery. status.py
// reads it over HID++ at most once a minute (scripts/hidpp.py) and keeps the last
// reading while the mouse sleeps. No receiver, no card.
Item {
    id: root
    readonly property var mouse: Sys.mouse
    readonly property bool low: !!mouse && mouse.level <= 15 && !mouse.charging
    visible: mouse !== null
    implicitHeight: 36

    Glass { anchors.fill: parent; radius: 18 }
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 8
        Icon { name: "mouse"; size: 14 }
        Label {
            Layout.fillWidth: true
            text: root.mouse ? root.mouse.name : ""
            elide: Text.ElideRight
            font.pixelSize: 12
            font.weight: Font.Medium
        }
        Label {
            visible: !!root.mouse && !!root.mouse.dpi
            text: root.mouse && root.mouse.dpi ? root.mouse.dpi + " DPI" : ""
            font.pixelSize: 10
            font.features: { "tnum": 1 }
            color: Theme.dim
        }
        Icon {
            name: root.mouse && root.mouse.charging ? "battery-charging" : "battery-medium"
            size: 14
            color: root.low ? Theme.text : Theme.dim
        }
        Label {
            text: root.mouse ? root.mouse.level + "%" : ""
            font.pixelSize: 10
            font.features: { "tnum": 1 }
            color: root.low ? Theme.text : Theme.dim
        }
    }
}
