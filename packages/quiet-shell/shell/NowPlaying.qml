import QtQuick
import QtQuick.Effects
import QtQuick.Layouts

Item {
    id: root
    readonly property var media: Sys.media
    readonly property bool showsCover: media !== null && cover.status === Image.Ready

    Glass { anchors.fill: parent; radius: 30 }
    // The cover is the card's surface: it fills the glass, inside its lit edge, and
    // sinks into it behind the title.
    Image {
        id: cover
        anchors.fill: parent
        anchors.margins: 1
        visible: false
        layer.enabled: true
        source: root.media && root.media.art ? root.media.art : ""
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(328, 328)
    }
    Rectangle {
        id: coverShape
        anchors.fill: cover
        radius: 29
        visible: false
        layer.enabled: true
    }
    MultiEffect {
        id: coverArt
        anchors.fill: cover
        visible: root.showsCover
        source: cover
        maskEnabled: true
        maskSource: coverShape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.2
    }
    Rectangle {
        anchors.fill: cover
        radius: 29
        visible: root.showsCover
        gradient: Gradient {
            GradientStop { position: 0.1; color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0) }
            GradientStop { position: 0.44; color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.72) }
            GradientStop { position: 0.68; color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.9) }
        }
    }
    Column {
        anchors.centerIn: parent
        visible: root.media === null
        spacing: 6
        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "music"; size: 22; color: Theme.dim }
        Label { anchors.horizontalCenter: parent.horizontalCenter; text: "Not playing"; font.pixelSize: 12; color: Theme.dim }
    }
    // Keeps the hint readable over a bright cover.
    Rectangle {
        visible: root.showsCover && keyHint.visible
        anchors.fill: keyHint
        anchors.margins: -4
        radius: 7
        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.72)
    }
    KeyHint {
        id: keyHint
        visible: root.media !== null && Ui.panel === "controls"
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.top: parent.top
        anchors.topMargin: 11
        text: "K ␣ J"
    }
    Icon { anchors.horizontalCenter: parent.horizontalCenter; y: 26; visible: root.media !== null && !root.showsCover; name: "music"; size: 20; color: Theme.dim }
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
            model: [["skip-back", "previous", "Previous track (K)"], [root.media && root.media.playing ? "pause" : "play", "play-pause", "Play or pause (Space)"], ["skip-forward", "next", "Next track (J)"]]
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
