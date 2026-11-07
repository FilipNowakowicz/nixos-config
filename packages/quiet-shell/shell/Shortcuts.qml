import QtQuick
import QtQuick.Layouts

// SUPER+/. Written by hand so it can explain itself. The test suite checks each entry
// against Hyprland's real binds, so this list can't quietly go stale.
Item {
    id: root
    implicitWidth: 720

    function pretty(keys) {
        const names = { SUPER: "Super", SHIFT: "⇧", CTRL: "Ctrl", apostrophe: "'", minus: "−", slash: "/", Return: "⏎", BackSpace: "⌫", Space: "Space", Tab: "Tab" };
        return keys.split(" + ").map(k => names[k] || k.toUpperCase()).join(" ");
    }
    implicitHeight: columns.implicitHeight + 40
    MouseArea { anchors.fill: parent }
    Glass { anchors.fill: parent; radius: 26 }
    RowLayout {
        id: columns
        x: 24
        y: 20
        width: parent.width - 48
        spacing: 32
        Repeater {
            model: Ui.shortcuts
            ColumnLayout {
                required property var modelData
                Layout.alignment: Qt.AlignTop
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                spacing: 3
                Repeater {
                    model: parent.modelData
                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.topMargin: modelData.length === 1 ? 8 : 0
                        spacing: 8
                        Label {
                            Layout.fillWidth: true
                            text: parent.modelData.length === 1 ? parent.modelData[0] : parent.modelData[1]
                            font.pixelSize: parent.modelData.length === 1 ? 12 : 13
                            font.weight: parent.modelData.length === 1 ? Font.DemiBold : Font.Normal
                            color: parent.modelData.length === 1 ? Theme.dim : Theme.text
                        }
                        Label {
                            visible: parent.modelData.length > 1
                            text: visible ? root.pretty(parent.modelData[0]) : ""
                            color: Theme.dim
                        }
                    }
                }
            }
        }
    }
}
