import QtQuick
import QtQuick.Layouts

// SUPER+SHIFT+S. Pick what to capture, then the bar gets out of the picture.
Item {
    id: root
    implicitWidth: row.implicitWidth + 16
    implicitHeight: 76
    MouseArea { anchors.fill: parent }
    Glass { anchors.fill: parent; radius: 26 }
    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 4
        Repeater {
            model: [["area", "Area", "square-dashed"], ["window", "Window", "app-window"], ["screen", "Screen", "monitor"]]
            Press {
                required property var modelData
                implicitWidth: 76
                implicitHeight: 60
                radius: 16
                name: "Capture " + modelData[1].toLowerCase()
                onClicked: Sys.screenshot(modelData[0])
                Column {
                    anchors.centerIn: parent
                    spacing: 5
                    Icon { anchors.horizontalCenter: parent.horizontalCenter; name: modelData[2]; size: 20 }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[1]; font.pixelSize: 12 }
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
