import QtQuick
import QtQuick.Layouts

Item {
    id: root
    property string writeKey
    visible: Sys.failed(writeKey)
    implicitHeight: visible ? 42 : 0
    Glass { anchors.fill: parent; radius: 21 }
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 8
        spacing: 8
        Icon { name: "triangle-alert"; size: 14 }
        Label { Layout.fillWidth: true; text: Sys.failMessage(root.writeKey); font.pixelSize: 12 }
        Press {
            name: "Retry"
            implicitWidth: 56
            implicitHeight: 26
            radius: 13
            rest: Theme.fill
            onClicked: Sys.retry(root.writeKey)
            Label { anchors.centerIn: parent; text: "Retry"; font.pixelSize: 12; font.weight: Font.Medium }
        }
        Press {
            name: "Dismiss"
            implicitWidth: 26
            implicitHeight: 26
            radius: 13
            onClicked: Sys.dismiss(root.writeKey)
            Icon { anchors.centerIn: parent; name: "x"; size: 13 }
        }
    }
}
