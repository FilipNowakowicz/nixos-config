import QtQuick
import QtQuick.Layouts

// The pill connects the Buds. Once they're connected, the row sets noise control.
ColumnLayout {
    id: root
    readonly property bool connected: !!Sys.buds && Sys.buds.connected
    readonly property var info: Sys.budsInfo
    function percent(label, value) { return value === null || value === undefined ? "" : label + value + "%"; }
    readonly property string battery: {
        const parts = root.info ? [percent("L ", root.info.left), percent("R ", root.info.right), percent("Case ", root.info.case)].filter(p => p) : [];
        if (parts.length)
            return parts.join(" · ");
        return Sys.buds && Sys.buds.battery !== null ? Sys.buds.battery + "%" : "Connected";
    }

    visible: Sys.buds !== null
    spacing: 8

    Pill {
        Layout.fillWidth: true
        name: Sys.buds ? Sys.buds.name : ""
        icon: "headphones"
        hint: "B"
        subtitle: Sys.pending("buds") ? "Working…" : root.connected ? root.battery : "Not connected"
        on: root.connected
        writeKey: "buds"
        onToggle: Sys.toggleBuds()
    }
    Item {
        visible: root.connected
        Layout.fillWidth: true
        implicitHeight: 42
        Glass { anchors.fill: parent; radius: 21 }
        RowLayout {
            anchors.fill: parent
            anchors.margins: 5
            spacing: 4
            Repeater {
                model: [["off", "Off"], ["ambient", "Ambient"], ["anc", "ANC"]]
                Press {
                    id: mode
                    required property var modelData
                    readonly property bool selected: !!root.info && root.info.mode === modelData[0]
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 16
                    name: "Noise control " + modelData[1]
                    checkable: true
                    toggled: selected
                    rest: selected ? Theme.on : "transparent"
                    hover: selected ? Theme.on : Theme.fillHover
                    onClicked: Sys.setBudsMode(modelData[0])
                    Label { anchors.centerIn: parent; text: mode.modelData[1]; font.pixelSize: 12; font.weight: Font.Medium; color: mode.selected ? Theme.onText : Theme.text }
                }
            }
        }
    }
}
