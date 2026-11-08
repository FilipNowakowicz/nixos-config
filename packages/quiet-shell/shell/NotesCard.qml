import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// The top of the notes file, so a thought jotted down earlier is in view in the
// overview. Clicking opens the file (SUPER+SHIFT+N does too).
Item {
    id: root
    implicitHeight: body.implicitHeight + 24
    readonly property var lines: file.text().split("\n").map(l => l.replace(/\s+$/, "")).filter(l => l.trim() !== "")

    FileView {
        id: file
        path: Sys.notesPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    Glass { anchors.fill: parent; radius: 22 }
    Press {
        anchors.fill: parent
        radius: 22
        name: "Open notes"
        onClicked: { Ui.close(); Sys.openNotes(); }
    }
    ColumnLayout {
        id: body
        x: 16
        y: 12
        width: parent.width - 32
        spacing: 3
        RowLayout {
            Layout.fillWidth: true
            Label { Layout.fillWidth: true; text: "Notes"; font.pixelSize: 12; font.weight: Font.Medium }
            Label { text: "Super ⇧ N"; font.pixelSize: 10; color: Theme.faint }
        }
        Label {
            visible: root.lines.length === 0
            Layout.fillWidth: true
            text: "Nothing written yet"
            font.pixelSize: 12
            color: Theme.dim
        }
        Repeater {
            model: root.lines.slice(0, 8)
            Label {
                required property string modelData
                Layout.fillWidth: true
                // Headings stand out a little; everything else reads as plain text.
                text: modelData.replace(/^#+\s*/, "")
                font.pixelSize: 12
                font.weight: modelData.startsWith("#") ? Font.Medium : Font.Normal
                color: modelData.startsWith("#") ? Theme.text : Theme.dim
            }
        }
        Label {
            visible: root.lines.length > 8
            text: "+" + (root.lines.length - 8) + " more"
            font.pixelSize: 11
            color: Theme.faint
        }
    }
}
