import QtQuick

Rectangle {
    property color tint: Theme.text
    implicitWidth: 15
    implicitHeight: 15
    radius: 8
    color: "transparent"
    border.width: 2
    border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.3)
    Rectangle {
        width: 4
        height: 4
        radius: 2
        x: parent.width / 2 - 2
        y: -1
        color: parent.tint
    }
    // A running animation keeps the whole shell redrawing every frame, even inside
    // a closed panel, so spin only while actually shown.
    RotationAnimation on rotation {
        running: visible
        loops: Animation.Infinite
        from: 0
        to: 360
        duration: 800
    }
}
