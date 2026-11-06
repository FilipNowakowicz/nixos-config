import QtQuick
import QtQuick.Layouts

Item {
    id: root
    implicitHeight: body.implicitHeight + 16
    readonly property string kind: Ui.detail
    readonly property string title: ({ wifi: "Wi-Fi", bluetooth: "Bluetooth", vpn: "VPN", sound: "Sound", theme: "Theme" })[kind] || ""

    Glass { anchors.fill: parent; radius: 26 }
    ColumnLayout {
        id: body
        x: 8
        y: 8
        width: parent.width - 16
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            spacing: 6
            Press {
                implicitWidth: 28
                implicitHeight: 28
                radius: 14
                name: "Back"
                onClicked: Ui.detail = ""
                Icon { anchors.centerIn: parent; name: "chevron-left"; size: 15 }
            }
            Label { text: root.title; font.weight: Font.DemiBold; font.pixelSize: 14 }
        }

        // Wi-Fi
        Repeater {
            model: root.kind === "wifi" && Sys.state.wifi ? Sys.state.wifi.networks : []
            DetailRow {
                required property var modelData
                Layout.fillWidth: true
                name: modelData.name
                title: modelData.name
                note: modelData.signal + "%"
                selected: modelData.active
                busy: Sys.pending("wifi-net")
                onClicked: if (!modelData.active) Sys.joinWifi(modelData.name)
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "wifi-net" }

        // Bluetooth
        Repeater {
            model: root.kind === "bluetooth" ? Sys.btDevices : []
            DetailRow {
                required property var modelData
                Layout.fillWidth: true
                name: modelData.name
                title: modelData.name
                note: modelData.connected ? "Connected" : "Paired"
                selected: modelData.connected
                busy: Sys.pending("bt-" + modelData.addr)
                onClicked: Sys.toggleDevice(modelData)
            }
        }
        Repeater {
            model: root.kind === "bluetooth" ? Sys.btDevices : []
            FailRow { required property var modelData; Layout.fillWidth: true; writeKey: "bt-" + modelData.addr }
        }

        // VPN
        DetailRow {
            visible: root.kind === "vpn"
            Layout.fillWidth: true
            name: "Tailscale"
            title: "Tailscale"
            note: Sys.tailscaleOn ? "Connected" : "Off"
            selected: Sys.tailscaleOn
            busy: Sys.pending("tailscale")
            onClicked: Sys.toggleTailscale()
        }
        DetailRow {
            visible: root.kind === "vpn"
            Layout.fillWidth: true
            name: "Mullvad"
            title: "Mullvad"
            note: Sys.mullvadOn ? "Connected" : "Off"
            selected: Sys.mullvadOn
            busy: Sys.pending("mullvad")
            onClicked: Sys.toggleMullvad()
        }

        // Sound
        Label { visible: root.kind === "sound"; Layout.leftMargin: 10; Layout.topMargin: 4; text: "Output"; font.pixelSize: 12; color: Theme.dim }
        Repeater {
            model: root.kind === "sound" && Sys.state.devices ? Sys.state.devices.sinks : []
            DetailRow {
                required property var modelData
                Layout.fillWidth: true
                name: modelData.desc
                title: modelData.desc
                selected: modelData.active
                busy: Sys.pending("device-sink")
                onClicked: if (!modelData.active) Sys.setDefaultDevice("sink", modelData.name)
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "device-sink" }
        Label { visible: root.kind === "sound"; Layout.leftMargin: 10; Layout.topMargin: 6; text: "Microphone"; font.pixelSize: 12; color: Theme.dim }
        ThinSlider {
            visible: root.kind === "sound"
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            name: "Microphone level"
            level: Sys.micLevel
            onChanged: value => Sys.setLevel("source", value)
        }
        Repeater {
            model: root.kind === "sound" && Sys.state.devices ? Sys.state.devices.sources : []
            DetailRow {
                required property var modelData
                Layout.fillWidth: true
                name: modelData.desc
                title: modelData.desc
                selected: modelData.active
                busy: Sys.pending("device-source")
                onClicked: if (!modelData.active) Sys.setDefaultDevice("source", modelData.name)
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "device-source" }

        // Theme
        Repeater {
            model: root.kind === "theme" ? Theme.themes : []
            DetailRow {
                required property var modelData
                Layout.fillWidth: true
                name: modelData
                title: modelData.split("-").map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(" ")
                selected: modelData === Theme.name
                busy: Sys.pending("theme")
                onClicked: Sys.setTheme(modelData)
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "theme" }
    }
}
