import QtQuick
import QtQuick.Effects

// One piece of glass. The blur is drawn by Hyprland from this item's alpha, through
// the layer rule on the quiet-shell namespace. Never put Glass inside Glass.
Item {
    id: root
    property real radius: 22
    property color tint: Theme.glass
    property bool lit: true

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.tint
    }
    Rectangle {
        id: edge
        anchors.fill: parent
        radius: root.radius
        visible: false
        layer.enabled: root.lit
        gradient: Gradient {
            GradientStop { position: 0; color: Theme.litEdge }
            GradientStop { position: 0.35; color: Theme.hairline }
            GradientStop { position: 1; color: Theme.hairline }
        }
    }
    Rectangle {
        id: ring
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: 1
        border.color: "white"
        visible: false
        layer.enabled: root.lit
    }
    MultiEffect {
        anchors.fill: parent
        visible: root.lit
        source: edge
        maskEnabled: true
        maskSource: ring
        maskThresholdMin: 0.1
    }
}
