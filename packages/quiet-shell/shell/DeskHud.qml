import QtQuick

// Where you just landed. The bar is usually hidden when you change desktop.
Item {
    id: root
    readonly property int desk: Ui.deskHud
    implicitWidth: dots.implicitWidth + 28
    implicitHeight: 36
    opacity: desk > 0 ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.motion } }

    // Kept while fading out.
    property int shown: 0
    onDeskChanged: if (desk > 0) shown = desk

    Glass { anchors.fill: parent; radius: 18 }
    Row {
        id: dots
        anchors.centerIn: parent
        spacing: 0
        Repeater {
            model: Dockable.desks
            Item {
                required property var modelData
                required property int index
                readonly property bool active: modelData.id === root.shown
                readonly property bool occupied: modelData.apps.length > 0
                width: index === 4 ? 21 : 15
                height: 16
                Rectangle {
                    x: 7.5 - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.active ? 9 : parent.occupied ? 7 : 5
                    height: width
                    radius: width / 2
                    color: parent.active ? Theme.text : parent.occupied ? Theme.dim : "transparent"
                    border.width: parent.active || parent.occupied ? 0 : 1
                    border.color: Theme.faint
                }
            }
        }
    }
}
