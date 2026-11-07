import QtQuick
import QtQuick.Layouts

// The wide control. The whole pill highlights and opens details, and the round icon
// sits on top as its own switch. With only one action, the icon is just a picture.
Item {
    id: root
    property string name
    property string subtitle
    property string icon
    property bool on: false
    property string writeKey
    property string detail
    property bool toggles: true
    property string hint
    readonly property bool single: !toggles || detail === ""
    signal toggle

    implicitWidth: 166
    implicitHeight: 62

    Glass { anchors.fill: parent; radius: 31 }
    Press {
        anchors.fill: parent
        radius: 31
        name: root.single ? root.name : root.name + " details"
        checkable: root.single && root.detail === ""
        toggled: root.on
        onClicked: root.detail !== "" ? Ui.detail = root.detail : root.toggle()
    }
    Press {
        id: circle
        x: 11
        anchors.verticalCenter: parent.verticalCenter
        width: 40
        height: 40
        radius: 20
        enabled: !root.single
        Accessible.ignored: root.single
        name: root.name
        checkable: true
        toggled: root.on
        rest: root.on ? Theme.on : Theme.fill
        hover: root.on ? Theme.on : Theme.fillHover
        onClicked: root.toggle()
        Icon { anchors.centerIn: parent; visible: !Sys.pending(root.writeKey); name: root.icon; size: 18; color: root.on ? Theme.onText : Theme.text }
        Spinner { anchors.centerIn: parent; visible: Sys.pending(root.writeKey); tint: root.on ? Theme.onText : Theme.text }
    }
    KeyHint {
        anchors.right: parent.right
        anchors.rightMargin: 18
        anchors.top: parent.top
        anchors.topMargin: 11
        text: root.hint
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
