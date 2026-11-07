import QtQuick
import Quickshell.Hyprland

// SUPER+Tab. Most recent window first, starting on the one before this.
Item {
    id: root
    readonly property var windows: Ui.switcher ? Dockable.recentWindows : []
    readonly property int cardWidth: 216
    readonly property int cardHeight: 166
    readonly property int perRow: Math.max(1, Math.floor(((parent ? parent.width : 1200) - 100 + grid.spacing) / (cardWidth + grid.spacing)))
    implicitWidth: grid.width + 20
    implicitHeight: grid.implicitHeight + 20

    Glass { anchors.fill: parent; radius: 26 }
    Flow {
        id: grid
        x: 10
        y: 10
        width: Math.min(root.windows.length, root.perRow) * (root.cardWidth + spacing) - spacing
        spacing: 6
        Repeater {
            model: root.windows
            Press {
                id: card
                required property var modelData
                required property int index
                readonly property string appId: modelData.wayland ? modelData.wayland.appId : ""
                width: root.cardWidth
                height: root.cardHeight
                radius: 16
                rest: index === Ui.switcherIndex ? Theme.fill : "transparent"
                name: modelData.title
                onClicked: { Ui.switcherIndex = index; Ui.commitSwitcher(); }
                WindowPreview {
                    x: 8
                    y: 8
                    width: parent.width - 16
                    height: 120
                    opacity: Dockable.isHidden(card.modelData) ? 0.45 : 1
                    toplevel: card.modelData.wayland ?? null
                    appId: card.appId
                }
                AppIcon {
                    id: badge
                    x: 12
                    y: 136
                    size: 20
                    icon: Dockable.iconOf(card.appId)
                    fallback: Dockable.nameOf(card.appId || "?")
                }
                Label {
                    x: 38
                    y: 136
                    width: parent.width - 48
                    height: 20
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    font.pixelSize: 12
                    text: card.modelData.title || Dockable.nameOf(card.appId)
                }
            }
        }
    }
}
