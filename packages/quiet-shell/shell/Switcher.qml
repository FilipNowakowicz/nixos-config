import QtQuick
import Quickshell.Hyprland

// SUPER+Tab. Most recent window first, starting on the one before this.
Item {
    id: root
    readonly property var windows: Ui.switcher ? Dockable.recentWindows : []
    implicitWidth: Math.min(row.implicitWidth, parent ? parent.width - 80 : row.implicitWidth) + 20
    implicitHeight: 148

    Glass { anchors.fill: parent; radius: 26 }
    Row {
        id: row
        x: 10
        y: 10
        spacing: 6
        Repeater {
            model: root.windows
            Press {
                id: card
                required property var modelData
                required property int index
                readonly property string appId: modelData.wayland ? modelData.wayland.appId : ""
                width: 116
                height: 128
                radius: 16
                rest: index === Ui.switcherIndex ? Theme.fill : "transparent"
                name: modelData.title
                onClicked: { Ui.switcherIndex = index; Ui.commitSwitcher(); }
                AppIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 12
                    size: 64
                    icon: Dockable.iconOf(card.appId)
                    fallback: Dockable.nameOf(card.appId || "?")
                    opacity: Dockable.isHidden(card.modelData) ? 0.45 : 1
                }
                Label {
                    x: 8
                    y: 84
                    width: parent.width - 16
                    height: 34
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignTop
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    font.pixelSize: 12
                    text: card.modelData.title || Dockable.nameOf(card.appId)
                }
            }
        }
    }
}
