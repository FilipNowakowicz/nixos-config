import QtQuick

// Under the screenshot picker: dragging anywhere on the screen captures that area,
// without choosing Area first. A click that doesn't drag closes the picker, as a
// click outside any panel does.
MouseArea {
    id: root
    // The screen's place in Hyprland's layout, which grim's region is measured in.
    property point origin: Qt.point(0, 0)
    property point start: Qt.point(0, 0)
    readonly property bool dragging: pressed && (Math.abs(mouseX - start.x) > 3 || Math.abs(mouseY - start.y) > 3)
    readonly property rect area: Qt.rect(Math.min(start.x, mouseX), Math.min(start.y, mouseY), Math.abs(mouseX - start.x), Math.abs(mouseY - start.y))

    cursorShape: Qt.CrossCursor
    onPressed: mouse => start = Qt.point(mouse.x, mouse.y)
    onReleased: {
        if (!dragging) {
            Ui.close();
            return;
        }
        const a = area;
        Sys.screenshot("area", `${Math.round(origin.x + a.x)},${Math.round(origin.y + a.y)} ${Math.max(1, Math.round(a.width))}x${Math.max(1, Math.round(a.height))}`);
    }

    // Keep the desktop sharp: translucent paint across this layer asks Hyprland
    // to blur the whole screen, hiding the detail the user is trying to select.
    Rectangle {
        visible: root.dragging
        x: root.area.x
        y: root.area.y
        width: root.area.width
        height: root.area.height
        color: "transparent"
        border.width: 2
        border.color: Theme.on
    }
}
