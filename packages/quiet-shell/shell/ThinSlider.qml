import QtQuick
import QtQuick.Controls.Basic

// The native control keeps keyboard and accessibility. Only its parts are restyled:
// a 4px line and a small pill knob that grows while held.
Slider {
    id: root
    property int level: 0
    property string name
    signal changed(int value)

    from: 0
    to: 100
    stepSize: 1
    implicitHeight: 18
    Accessible.name: name
    Binding on value { when: !root.pressed; value: root.level; restoreMode: Binding.RestoreNone }
    onMoved: root.changed(Math.round(value))
    onPressedChanged: Ui.dragging = pressed

    background: Item {
        x: root.leftPadding
        y: root.topPadding + root.availableHeight / 2 - 2
        width: root.availableWidth
        height: 4
        Rectangle { anchors.fill: parent; radius: 2; color: Theme.track }
        Rectangle {
            width: root.visualPosition * parent.width
            height: parent.height
            radius: 2
            color: Theme.text
        }
    }
    handle: Rectangle {
        x: root.leftPadding + root.visualPosition * (root.availableWidth - width)
        y: root.topPadding + root.availableHeight / 2 - height / 2
        width: root.pressed ? 27 : 22
        height: root.pressed ? 17 : 14
        radius: height / 2
        color: Theme.text
        border.width: root.activeFocus ? 2 : 0
        border.color: Theme.accent
        Behavior on width { NumberAnimation { duration: 90 } }
        Behavior on height { NumberAnimation { duration: 90 } }
    }
}
