import QtQuick
import QtQuick.Layouts

// SUPER+SHIFT+S. Pick what to capture with a click or 1 to 4, or drag anywhere for
// an area straight away (AreaDrag). Then the bar gets out of the picture.
Item {
    id: root
    readonly property var modes: [["area", "Area", "square-dashed"], ["window", "Window", "app-window"], ["screen", "Screen", "monitor"], ["text", "Text", "scan-text"]]
    function pressKey(text) {
        const mode = modes[parseInt(text) - 1];
        if (!mode)
            return false;
        Sys.screenshot(mode[0]);
        return true;
    }
    implicitWidth: row.implicitWidth + 16
    implicitHeight: 76
    MouseArea { anchors.fill: parent }
    Glass { anchors.fill: parent; radius: 26 }
    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 4
        Repeater {
            model: root.modes
            Press {
                required property var modelData
                required property int index
                implicitWidth: 76
                implicitHeight: 60
                radius: 16
                name: modelData[0] === "text" ? "Copy text from an area" : "Capture " + modelData[1].toLowerCase()
                onClicked: Sys.screenshot(modelData[0])
                Column {
                    anchors.centerIn: parent
                    spacing: 5
                    Icon { anchors.horizontalCenter: parent.horizontalCenter; name: modelData[2]; size: 20 }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[1]; font.pixelSize: 12 }
                }
                Label {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 6
                    text: index + 1
                    font.pixelSize: 10
                    font.weight: Font.Medium
                    color: Theme.faint
                }
            }
        }
        Rectangle { Layout.leftMargin: 4; Layout.rightMargin: 4; implicitWidth: 1; implicitHeight: 40; color: Theme.hairline }
        Press {
            implicitWidth: 60
            implicitHeight: 60
            radius: 16
            name: "Cancel"
            onClicked: Ui.close()
            Label { anchors.centerIn: parent; text: "Cancel"; font.pixelSize: 12; color: Theme.dim }
        }
    }
}
