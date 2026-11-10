import QtQuick
import QtQuick.Effects
import QtQuick.Layouts

Item {
    id: root
    readonly property var media: Sys.media
    readonly property bool showsCover: media !== null && (coverOne.shown || coverTwo.shown)
    readonly property string art: media && media.art ? media.art : ""
    readonly property var covers: [coverOne, coverTwo]
    property int front: 0

    onArtChanged: showArt()
    Component.onCompleted: showArt()

    // The new cover loads out of sight and fades in on top of the old one, so the card
    // never drops to its empty state. Art can arrive just after the title.
    function showArt() {
        if (art === "") {
            noArt.restart();
            return;
        }
        noArt.stop();
        if (covers[front].url === art && covers[front].shown)
            return;
        const back = covers[1 - front];
        back.url = art;
        if (back.ready)
            reveal(back);
    }
    function reveal(cover) {
        if (cover.url !== art)
            return;
        front = covers.indexOf(cover);
        cover.shown = true;
        retire.restart();
    }
    function clearCovers() {
        for (const cover of covers) {
            cover.shown = false;
            cover.url = "";
        }
    }
    Timer {
        id: noArt
        interval: 1200
        onTriggered: if (root.art === "") root.clearCovers()
    }
    // Once the fade has finished, the cover underneath can go.
    Timer {
        id: retire
        interval: 320
        onTriggered: {
            const old = root.covers[1 - root.front];
            old.shown = false;
            if (old.url !== root.art)
                old.url = "";
        }
    }

    component Cover: Item {
        id: face
        property string url
        property bool shown: false
        readonly property bool ready: picture.status === Image.Ready
        signal loaded
        signal failed
        anchors.fill: parent
        anchors.margins: 1
        opacity: shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
        Image {
            id: picture
            anchors.fill: parent
            visible: false
            layer.enabled: true
            source: face.url
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(328, 328)
            onStatusChanged: {
                if (status === Image.Ready) face.loaded();
                else if (status === Image.Error) face.failed();
            }
        }
        Rectangle {
            id: shape
            anchors.fill: parent
            radius: 29
            visible: false
            layer.enabled: true
        }
        MultiEffect {
            anchors.fill: parent
            source: picture
            maskEnabled: true
            maskSource: shape
            maskThresholdMin: 0.5
            maskSpreadAtMin: 0.2
        }
    }

    Glass { anchors.fill: parent; radius: 30 }
    // The cover is the card's surface: it fills the glass, inside its lit edge, and
    // sinks into it behind the title.
    Item {
        anchors.fill: parent
        visible: root.media !== null
        Cover {
            id: coverOne
            z: root.front === 0 ? 1 : 0
            onLoaded: root.reveal(coverOne)
            onFailed: if (url === root.art) root.clearCovers()
        }
        Cover {
            id: coverTwo
            z: root.front === 1 ? 1 : 0
            onLoaded: root.reveal(coverTwo)
            onFailed: if (url === root.art) root.clearCovers()
        }
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
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
        text: "J ␣ K"
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
            model: [["skip-back", "previous", "Previous track (J)"], [root.media && root.media.playing ? "pause" : "play", "play-pause", "Play or pause (Space)"], ["skip-forward", "next", "Next track (K)"]]
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
