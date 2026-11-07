import QtQuick
import Quickshell

Item {
    id: root
    property string icon
    property string fallback
    property string glyph
    property int size: 44
    implicitWidth: size
    implicitHeight: size

    readonly property string path: icon ? Quickshell.iconPath(icon, true) : ""
    Image {
        anchors.fill: parent
        source: root.path
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        visible: root.path !== "" && root.glyph === ""
    }
    Rectangle {
        anchors.fill: parent
        visible: root.path === "" || root.glyph !== ""
        radius: root.size * 0.24
        color: Theme.fill
        Icon { anchors.centerIn: parent; visible: root.glyph !== ""; name: root.glyph; size: root.size * 0.55 }
        Label {
            anchors.centerIn: parent
            visible: root.glyph === ""
            text: root.fallback.charAt(0).toUpperCase()
            font.pixelSize: root.size * 0.45
            font.weight: Font.Medium
        }
    }
}
