import QtQuick
import Quickshell.Wayland

// A window's live picture. It takes a moment to arrive, so the icon only appears if it
// doesn't: showing the icon straight away reads as a flash.
Item {
    id: root
    property var toplevel: null
    property string appId
    property int iconSize: 64
    property size captureSize: Qt.size(432, 240)

    property bool late: false
    Timer { interval: 500; running: true; onTriggered: root.late = true }

    AppIcon {
        anchors.centerIn: parent
        visible: root.late && !capture.hasContent
        size: root.iconSize
        icon: Dockable.iconOf(root.appId)
        fallback: Dockable.nameOf(root.appId || "?")
    }
    ScreencopyView {
        id: capture
        anchors.fill: parent
        captureSource: root.toplevel
        live: true
        constraintSize: root.captureSize
        opacity: hasContent ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.motion / 2 } }
    }
}
