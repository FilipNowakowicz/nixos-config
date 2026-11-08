import QtQuick

Press {
    id: root
    property string title
    property string note
    property bool selected: false
    property bool busy: false
    property bool locked: false
    property string hint
    implicitHeight: 34
    radius: 10
    Label { x: 10; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 90; text: root.title; font.weight: root.selected ? Font.Medium : Font.Normal }
    Label { id: noteText; anchors.right: parent.right; anchors.rightMargin: root.selected || root.busy ? 30 : 10; anchors.verticalCenter: parent.verticalCenter; text: root.note; font.pixelSize: 12; color: Theme.dim }
    KeyHint { anchors.right: noteText.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: root.hint }
    Icon { visible: root.locked; anchors.right: noteText.left; anchors.rightMargin: 5; anchors.verticalCenter: parent.verticalCenter; name: "lock"; size: 12; color: Theme.dim }
    Icon { visible: root.selected && !root.busy; anchors.right: parent.right; anchors.rightMargin: 9; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 14 }
    Spinner { visible: root.busy; anchors.right: parent.right; anchors.rightMargin: 9; anchors.verticalCenter: parent.verticalCenter }
}
