import QtQuick
import Quickshell.Widgets

// One theme in the picker: its wallpaper, cropped, with the theme's own colours
// along the bottom, so you see what you get before choosing it.
Press {
    id: root
    required property var entry
    property bool selected: false
    property bool busy: false
    property string cursorKey: "theme " + entry.name
    readonly property color base: entry.bg
    name: entry.title
    marked: cursorKey !== "" && Ui.detailCursor === cursorKey
    radius: 14
    implicitHeight: art.height + caption.implicitHeight + 14

    Item {
        id: art
        x: 5
        y: 5
        width: parent.width - 10
        height: Math.round(width * 9 / 16)

        // Clipped by the scene graph rather than a mask effect: an offscreen mask
        // missed thumbnails that finished loading while the panel was hidden.
        // The theme's background shows where there is no picture.
        ClippingRectangle {
            anchors.fill: parent
            radius: 10
            color: root.entry.bg
            Image {
                anchors.fill: parent
                source: root.entry.thumbnail
                fillMode: Image.PreserveAspectCrop
                // A 208x117 JPEG decodes in well under a frame, and loading in step
                // means a rebuilt tile never shows an empty frame first.
                asynchronous: false
                sourceSize: Qt.size(208, 117)
            }
        }

        // The theme's palette: surface, accent and text.
        Rectangle {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 5
            width: swatches.implicitWidth + 8
            height: 14
            radius: 7
            color: Qt.rgba(root.base.r, root.base.g, root.base.b, 0.8)
            Row {
                id: swatches
                anchors.centerIn: parent
                spacing: 3
                Repeater {
                    model: [root.entry.surface, root.entry.accent, root.entry.text]
                    Rectangle {
                        required property color modelData
                        width: 7
                        height: 7
                        radius: 3.5
                        color: modelData
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.12)
                    }
                }
            }
        }

        // The ring and tick mark the running theme.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: 13
            color: "transparent"
            border.width: 2
            border.color: Theme.accent
            opacity: root.selected ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.motion } }
        }
        Rectangle {
            visible: root.selected || root.busy
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 5
            width: 18
            height: 18
            radius: 9
            color: Theme.accent
            Icon { visible: !root.busy; anchors.centerIn: parent; name: "check"; size: 11; color: Theme.onText }
            Spinner { visible: root.busy; anchors.centerIn: parent; scale: 0.7; tint: Theme.onText }
        }
    }

    Label {
        id: caption
        anchors.top: art.bottom
        anchors.topMargin: 4
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 10
        horizontalAlignment: Text.AlignHCenter
        text: root.entry.title
        font.pixelSize: 11
        font.weight: root.selected ? Font.DemiBold : Font.Normal
        color: root.selected ? Theme.text : Theme.dim
    }
}
