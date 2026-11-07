import QtQuick

Item {
    id: root
    property string name
    property string icon
    property bool on: false
    property string writeKey
    property string hint
    signal activated
    implicitWidth: 62
    implicitHeight: 62

    Glass { anchors.fill: parent; radius: 31 }
    Press {
        anchors.fill: parent
        radius: 31
        name: root.name
        checkable: true
        toggled: root.on
        rest: root.on ? Theme.on : "transparent"
        hover: root.on ? Theme.on : Theme.fill
        onClicked: root.activated()
        Icon { anchors.centerIn: parent; visible: !Sys.pending(root.writeKey); name: root.icon; size: 20; color: root.on ? Theme.onText : Theme.text }
        Spinner { anchors.centerIn: parent; visible: Sys.pending(root.writeKey); tint: root.on ? Theme.onText : Theme.text }
    }
    KeyHint {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        text: root.hint
        color: root.on ? Theme.onText : Theme.faint
    }
}
