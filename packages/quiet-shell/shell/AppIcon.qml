import QtQuick
import QtQuick.Effects
import Quickshell

// An app's own icon. Icons big enough to read sit on one shared tile, so their
// different shapes still line up. With monochrome icons on, an icon shows its colour
// only while `lit`: pointed at, selected, or the window in focus.
Item {
    id: root
    property string icon
    property string fallback
    property string glyph
    property int size: 44
    property bool lit: false
    implicitWidth: size
    implicitHeight: size

    readonly property string path: icon ? Quickshell.iconPath(icon, true) : ""
    readonly property bool picture: path !== "" && glyph === ""
    // Below this a tile leaves too little room for the icon, as on switcher title badges.
    readonly property bool tiled: size >= 28
    property real grey: Theme.monoIcons && !lit ? 1 : 0
    Behavior on grey { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }

    Rectangle {
        anchors.fill: parent
        visible: !root.picture || root.tiled
        radius: root.size * 0.24
        color: Theme.fill
        Icon { anchors.centerIn: parent; visible: root.glyph !== ""; name: root.glyph; size: root.size * 0.55 }
        Label {
            anchors.centerIn: parent
            visible: !root.picture && root.glyph === ""
            text: root.fallback.charAt(0).toUpperCase()
            font.pixelSize: root.size * 0.45
            font.weight: Font.Medium
        }
    }
    Image {
        anchors.centerIn: parent
        width: root.tiled ? Math.round(root.size * 0.7) : root.size
        height: width
        source: root.path
        sourceSize: Qt.size(width * 2, height * 2)
        visible: root.picture
        opacity: 1 - 0.12 * root.grey
        // Only pay for the effect while some grey is showing.
        layer.enabled: root.grey > 0
        layer.effect: MultiEffect { saturation: -root.grey }
    }
}
