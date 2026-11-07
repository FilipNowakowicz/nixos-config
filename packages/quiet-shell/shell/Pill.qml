import QtQuick
import QtQuick.Layouts

// The wide control: a round toggle, then a label that opens details.
Item {
    id: root
    property string name
    property string subtitle
    property string icon
    property bool on: false
    property string writeKey
    property string detail
    signal toggle

    implicitWidth: 166
    implicitHeight: 62

    Glass { anchors.fill: parent; radius: 31 }
    Press {
        id: circle
        x: 11
        anchors.verticalCenter: parent.verticalCenter
        width: 40
        height: 40
        radius: 20
        name: root.name
        checkable: true
        toggled: root.on
        rest: root.on ? Theme.on : Theme.fill
        hover: root.on ? Theme.on : Theme.fillHover
        onClicked: root.toggle()
        Icon { anchors.centerIn: parent; visible: !Sys.pending(root.writeKey); name: root.icon; size: 18; color: root.on ? Theme.onText : Theme.text }
        Spinner { anchors.centerIn: parent; visible: Sys.pending(root.writeKey); tint: root.on ? Theme.onText : Theme.text }
    }
    Press {
        anchors.left: circle.right
        anchors.leftMargin: 4
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        height: 44
        radius: 14
        rest: "transparent"
        // With nothing to open, the whole pill is the toggle.
        name: root.detail !== "" ? root.name + " details" : root.name + " label"
        onClicked: root.detail !== "" ? Ui.detail = root.detail : root.toggle()
    }
    Column {
        anchors.left: circle.right
        anchors.leftMargin: 9
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        Label { width: parent.width; text: root.name; font.pixelSize: 14; font.weight: Font.Medium }
        Label { width: parent.width; text: root.subtitle; font.pixelSize: 12; color: Theme.dim }
    }
}
