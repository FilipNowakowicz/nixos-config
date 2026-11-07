import QtQuick
import QtQuick.Effects

Item {
    id: root
    property string name
    property color color: Theme.text
    property int size: 16
    implicitWidth: size
    implicitHeight: size

    Image {
        id: glyph
        anchors.fill: parent
        source: root.name ? Qt.resolvedUrl("assets/icons/" + root.name + ".svg") : ""
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        visible: false
    }
    MultiEffect {
        anchors.fill: glyph
        source: glyph
        colorization: 1
        colorizationColor: root.color
        brightness: 1
    }
}
