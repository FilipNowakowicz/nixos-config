import QtQuick

// The volume and brightness pop-up. It takes no input and leaves on its own.
Item {
    id: root
    readonly property var hud: Ui.hud
    width: 240
    height: 44
    opacity: hud ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.motion } }

    // Kept while fading out, when `hud` is already gone.
    property var shown: null
    onHudChanged: if (hud) shown = hud

    Glass { anchors.fill: parent; radius: 22 }
    Icon {
        id: glyph
        x: 14
        anchors.verticalCenter: parent.verticalCenter
        name: !root.shown ? "sun" : root.shown.kind === "brightness" ? "sun" : root.shown.muted ? "volume-x" : "volume-2"
        size: 16
    }
    Rectangle {
        id: track
        anchors.left: glyph.right
        anchors.leftMargin: 11
        anchors.right: parent.right
        anchors.rightMargin: 18
        anchors.verticalCenter: parent.verticalCenter
        height: 4
        radius: 2
        color: Theme.track
        Rectangle {
            width: parent.width * (root.shown && !root.shown.muted ? root.shown.level : 0) / 100
            height: parent.height
            radius: 2
            color: Theme.on
            Behavior on width { NumberAnimation { duration: 90 } }
        }
    }
}
