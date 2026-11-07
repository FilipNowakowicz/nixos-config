import QtQuick
import QtQuick.Layouts

Item {
    id: root
    readonly property var media: Sys.media

    Glass { anchors.fill: parent; radius: 30 }
    Column {
        anchors.centerIn: parent
        visible: root.media === null
        spacing: 6
        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "music"; size: 22; color: Theme.dim }
        Label { anchors.horizontalCenter: parent.horizontalCenter; text: "Not playing"; font.pixelSize: 12; color: Theme.dim }
    }
    Rectangle {
        id: art
        visible: root.media !== null
        anchors.horizontalCenter: parent.horizontalCenter
        y: 12
        width: 48
        height: 48
        radius: 9
        color: Theme.fill
        clip: true
        Image {
            anchors.fill: parent
            visible: status === Image.Ready
            source: root.media && root.media.art ? root.media.art : ""
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(96, 96)
        }
        Icon { anchors.centerIn: parent; visible: !!root.media && !root.media.art; name: "music"; size: 20; color: Theme.dim }
    }
    Column {
        visible: root.media !== null
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        y: 63
        Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.media ? root.media.title : ""; font.weight: Font.Medium }
        Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.media ? root.media.artist : ""; font.pixelSize: 12; color: Theme.dim; visible: text !== "" }
    }
    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 11
        anchors.rightMargin: 11
        anchors.bottomMargin: 7
        visible: root.media !== null
        Repeater {
            model: [["skip-back", "previous", "Previous track"], [root.media && root.media.playing ? "pause" : "play", "play-pause", "Play or pause"], ["skip-forward", "next", "Next track"]]
            Press {
                required property var modelData
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: 34
                implicitHeight: 26
                radius: 9
                name: modelData[2]
                onClicked: Sys.mediaCommand(modelData[1])
                Icon { anchors.centerIn: parent; name: modelData[0]; size: 16 }
            }
        }
    }
}
