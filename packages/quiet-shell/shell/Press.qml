import QtQuick

// A pointer and keyboard target. `name` is what assistive tech and tests see.
Item {
    id: root
    property string name
    property bool toggled: false
    property bool checkable: false
    property bool marked: false          // Where a list's keyboard cursor is.
    property real radius: 12
    property color hover: Theme.fillHover
    property color rest: "transparent"
    readonly property bool hovered: area.containsMouse
    property Item dragTarget: null
    readonly property bool dragging: area.drag.active
    signal clicked
    signal pressedAt(real x, real y)
    signal dropped
    signal secondaryClicked

    activeFocusOnTab: true
    Accessible.role: checkable ? Accessible.CheckBox : Accessible.Button
    Accessible.name: name
    Accessible.checkable: checkable
    Accessible.checked: toggled
    Accessible.onPressAction: clicked()
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: area.containsMouse ? root.hover : root.rest
        border.width: root.activeFocus || root.marked ? 2 : 0
        border.color: Theme.accent
        Behavior on color { ColorAnimation { duration: 90 } }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        drag.target: root.dragTarget
        onPressed: mouse => root.pressedAt(mouse.x, mouse.y)
        onReleased: if (drag.active) root.dropped()
        onClicked: mouse => mouse.button === Qt.RightButton ? root.secondaryClicked() : root.clicked()
    }
}
