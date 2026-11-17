import QtQuick

// A SUPER shortcut drawn as the system's logo key and a letter, like the
// letters in the corners of the control centre's pills.
Row {
    id: root
    property string key
    property color tint: Theme.text
    spacing: 2
    opacity: 0.45
    Icon { anchors.verticalCenter: parent.verticalCenter; name: "nixos"; size: 9; color: root.tint }
    Label { anchors.verticalCenter: parent.verticalCenter; text: root.key; font.pixelSize: 10; font.weight: Font.Medium; color: root.tint }
}
