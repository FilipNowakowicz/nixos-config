import QtQuick

Item {
    id: root
    property var entry
    implicitWidth: 340
    implicitHeight: column.implicitHeight + 22
    Glass { anchors.fill: parent; radius: 22 }
    Column {
        id: column
        x: 14
        y: 11
        width: parent.width - 28
        Label { width: parent.width; text: root.entry ? root.entry.app + " · " + Qt.formatTime(root.entry.at, "HH:mm") : ""; font.pixelSize: 12; color: Theme.dim }
        Label { width: parent.width; text: root.entry ? root.entry.title : ""; font.weight: Font.Medium }
        Label { width: parent.width; text: root.entry ? root.entry.body : ""; font.pixelSize: 12; color: Theme.dim; visible: text !== ""; maximumLineCount: 3; wrapMode: Text.Wrap }
    }
}
