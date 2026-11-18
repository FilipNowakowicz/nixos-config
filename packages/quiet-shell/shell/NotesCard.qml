import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// The top of the notes file, so a thought jotted down earlier is in view in the
// overview. The chevron unfolds the whole file in place, to read without leaving;
// clicking anywhere else opens the file to edit (SUPER+SHIFT+N does too).
Item {
    id: root
    implicitHeight: body.implicitHeight + 24
    Behavior on implicitHeight { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
    readonly property var lines: file.text().split("\n").map(l => l.replace(/\s+$/, "")).filter(l => l.trim() !== "")
    // Folded, the card takes no more room than a handful of lines.
    readonly property int folded: 5
    property bool expanded: false
    // Unfolded, a long file scrolls inside the card rather than pushing the rest away.
    readonly property int tallest: 360

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
            Press {
                visible: root.lines.length > root.folded
                implicitWidth: 22
                implicitHeight: 22
                radius: 11
                name: root.expanded ? "Fold notes" : "Unfold notes"
                onClicked: root.expanded = !root.expanded
                Icon {
                    anchors.centerIn: parent
                    name: "chevron-down"
                    size: 14
                    color: Theme.dim
                    rotation: root.expanded ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: Theme.motion } }
                }
            }
        }
        Label {
            visible: root.lines.length === 0
            Layout.fillWidth: true
            text: "Nothing written yet"
            font.pixelSize: 12
            color: Theme.dim
        }
        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(lineColumn.implicitHeight, root.tallest)
            contentHeight: lineColumn.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            Column {
                id: lineColumn
                width: parent.width
                spacing: 3
                Repeater {
                    model: root.expanded ? root.lines : root.lines.slice(0, root.folded)
                    Label {
                        required property string modelData
                        width: lineColumn.width
                        // Headings stand out a little; everything else reads as plain text.
                        text: modelData.replace(/^#+\s*/, "")
                        // Unfolded is for reading, so long lines wrap; folded keeps one line each.
                        wrapMode: root.expanded ? Text.Wrap : Text.NoWrap
                        elide: root.expanded ? Text.ElideNone : Text.ElideRight
                        font.pixelSize: 12
                        font.weight: modelData.startsWith("#") ? Font.Medium : Font.Normal
                        color: modelData.startsWith("#") ? Theme.text : Theme.dim
                    }
                }
            }
        }
        Label {
            visible: !root.expanded && root.lines.length > root.folded
            text: "+" + (root.lines.length - root.folded) + " more"
            font.pixelSize: 11
            color: Theme.faint
        }
    }
}
