import QtQuick
import QtQuick.Layouts

Item {
    id: root
    readonly property bool hovered: hover.hovered
    implicitWidth: row.implicitWidth + 16
    implicitHeight: 68
    HoverHandler { id: hover }
    Glass { anchors.fill: parent; radius: 22 }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Repeater {
            model: Dockable.apps
            Press {
                id: item
                required property var modelData
                readonly property bool minimized: modelData.windows.every(Dockable.isHidden)
                readonly property bool here: modelData.windows.some(Dockable.here)
                width: 52
                height: 56
                radius: 13
                name: modelData.name
                onClicked: { Dockable.click(modelData); if (Ui.overview) Ui.close(); }
                AppIcon {
                    anchors.centerIn: parent
                    size: 44
                    icon: item.modelData.icon
                    fallback: item.modelData.name
                    opacity: item.minimized ? 0.45 : 1
                    scale: item.hovered ? 1.1 : 1
                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                }
                // Bright on this desktop, faint on another, gone when minimised.
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: 4
                    height: 4
                    radius: 2
                    color: item.here ? Theme.text : Theme.faint
                    visible: !item.minimized
                }
            }
        }
    }
}
