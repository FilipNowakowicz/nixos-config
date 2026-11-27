import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// The paired phone at a glance, over KDE Connect: whether it is in reach, its
// battery, and the notifications waiting on it.
// scripts/phone.py asks KDE Connect's daemon; it is asked only while the card is on
// screen, and without a paired phone the card stays away.
Item {
    id: root
    implicitHeight: body.implicitHeight + 24
    readonly property var phones: info ? info.phones : []
    readonly property bool hasContent: phones.length > 0
    visible: hasContent
    // The overview's column is short on room: two waiting notifications, the rest counted.
    readonly property int shown: 2

    property var info: null

    Process {
        id: probe
        command: ["python3", Qt.resolvedUrl("scripts/phone.py").toString().replace("file://", "")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.info = JSON.parse(text);
                } catch (e) {
                    console.warn("quiet-shell: bad phone output", e);
                }
            }
        }
    }
    Timer {
        interval: 20000
        // The overview, and so this card, only exists while it is open.
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!probe.running) probe.running = true
    }

    Glass { anchors.fill: parent; radius: 22 }
    ColumnLayout {
        id: body
        x: 16
        y: 12
        width: parent.width - 32
        spacing: 6

        Repeater {
            model: root.phones
            ColumnLayout {
                id: phone
                required property var modelData
                readonly property var notes: modelData.notifications
                readonly property int hidden: Math.max(0, notes.length - root.shown) + modelData.more
                Layout.fillWidth: true
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Icon { name: "smartphone"; size: 14; color: phone.modelData.reachable ? Theme.text : Theme.faint }
                    Label {
                        Layout.fillWidth: true
                        text: phone.modelData.name
                        elide: Text.ElideRight
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: phone.modelData.reachable ? Theme.text : Theme.dim
                    }
                    Label {
                        visible: !phone.modelData.reachable
                        text: "Not in reach"
                        font.pixelSize: 10
                        color: Theme.faint
                    }
                    Icon {
                        visible: !!phone.modelData.battery
                        name: phone.modelData.battery && phone.modelData.battery.charging ? "battery-charging" : "battery-medium"
                        size: 14
                        color: phone.modelData.battery && phone.modelData.battery.charge <= 15 && !phone.modelData.battery.charging ? Theme.text : Theme.dim
                    }
                    Label {
                        visible: !!phone.modelData.battery
                        text: phone.modelData.battery ? phone.modelData.battery.charge + "%" : ""
                        font.pixelSize: 10
                        font.features: { "tnum": 1 }
                        color: Theme.dim
                    }
                }
                Repeater {
                    model: phone.notes.slice(0, root.shown)
                    Label {
                        required property var modelData
                        Layout.fillWidth: true
                        // The app says who, the title says what; Messages puts the sender in the title.
                        text: [modelData.app, modelData.title].filter(s => s).join(" · ") + (modelData.text ? " — " + modelData.text : "")
                        elide: Text.ElideRight
                        font.pixelSize: 11
                        color: Theme.dim
                    }
                }
                Label {
                    visible: phone.hidden > 0
                    text: "+" + phone.hidden + " more on the phone"
                    font.pixelSize: 10
                    color: Theme.faint
                }
            }
        }
    }
}
