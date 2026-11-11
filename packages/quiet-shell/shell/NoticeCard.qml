import QtQuick
import QtQuick.Layouts
import Quickshell

Item {
    id: root
    property var entry
    property int more: 0
    signal showMore

    readonly property var source: entry ? entry.source : null
    readonly property var actions: source ? source.actions.filter(a => a.identifier !== "default") : entry && entry.actions ? entry.actions : []
    readonly property var primary: source ? source.actions.find(a => a.identifier === "default") : null
    readonly property bool hovered: hover.hovered
    readonly property string saved: entry && entry.image ? entry.image : ""

    implicitWidth: 340
    implicitHeight: Math.max(column.implicitHeight, 34) + 22
    HoverHandler { id: hover }
    Glass { anchors.fill: parent; radius: 22 }
    MouseArea {
        anchors.fill: parent
        cursorShape: root.primary || root.saved ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            if (root.primary) {
                Notify.invoke(root.entry, root.primary);
            } else if (root.saved) {
                Quickshell.execDetached(["xdg-open", root.saved]);
                Notify.remove(root.entry);
            }
        }
    }

    Image {
        id: picture
        x: 13
        y: 13
        width: 32
        height: 32
        source: root.source ? root.source.image : root.saved
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(64, 64)
        visible: status === Image.Ready
    }
    AppIcon {
        x: 13
        y: 13
        size: 32
        visible: !picture.visible
        // Copied off the notification, so a card the app withdrew keeps its icon.
        icon: root.entry && root.entry.icon ? root.entry.icon : ""
        lit: root.hovered
        fallback: root.entry ? root.entry.app : ""
        glyph: root.entry && root.entry.system ? "bell" : ""
    }
    ColumnLayout {
        id: column
        x: 55
        y: 11
        width: parent.width - 69
        spacing: 1
        Label { Layout.fillWidth: true; Layout.rightMargin: 16; text: root.entry ? root.entry.app + " · " + Qt.formatTime(root.entry.at, "HH:mm") : ""; font.pixelSize: 12; color: Theme.dim }
        Label { Layout.fillWidth: true; text: root.entry ? root.entry.title : ""; font.weight: Font.Medium }
        Label { Layout.fillWidth: true; text: root.entry ? root.entry.body : ""; font.pixelSize: 12; color: Theme.dim; visible: text !== ""; maximumLineCount: 3; wrapMode: Text.Wrap; textFormat: Text.PlainText }
        RowLayout {
            visible: root.actions.length > 0
            Layout.fillWidth: true
            Layout.topMargin: 6
            spacing: 6
            Repeater {
                model: root.actions.slice(0, 3)
                Press {
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: 26
                    radius: 10
                    rest: Theme.fill
                    name: modelData.text
                    onClicked: Notify.invoke(root.entry, modelData)
                    Label { anchors.centerIn: parent; width: parent.width - 12; horizontalAlignment: Text.AlignHCenter; text: parent.modelData.text; font.pixelSize: 12 }
                }
            }
        }
        Press {
            visible: root.more > 0
            Layout.topMargin: 4
            implicitWidth: moreText.implicitWidth + 16
            implicitHeight: 22
            radius: 11
            rest: Theme.fill
            name: root.more + " more from " + (root.entry ? root.entry.app : "")
            onClicked: root.showMore()
            Label { id: moreText; anchors.centerIn: parent; text: root.more + " more"; font.pixelSize: 11 }
        }
    }
    Press {
        visible: root.hovered && root.entry !== null
        x: parent.width - 28
        y: 8
        width: 20
        height: 20
        radius: 10
        rest: Theme.fill
        name: "Dismiss notification"
        onClicked: Notify.remove(root.entry)
        Icon { anchors.centerIn: parent; name: "x"; size: 11 }
    }
}
