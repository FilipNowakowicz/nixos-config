import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Pipewire

Item {
    id: root
    // The unsaved network waiting for a password, if any.
    property string asking: ""
    onKindChanged: {
        asking = "";
        if (kind === "wifi") Sys.rescanWifi();
        if (kind === "bluetooth") Sys.scanBluetooth();
        if (kind === "mullvad") Sys.loadCountries();
    }
    implicitHeight: body.implicitHeight + 16
    readonly property string kind: Ui.detail
    readonly property var exitNodes: Sys.state.vpn ? Sys.state.vpn.exitNodes : []
    readonly property string title: ({ wifi: "Wi-Fi", bluetooth: "Bluetooth", vpn: "VPN", sound: "Sound", theme: "Theme", mullvad: "Mullvad location" })[kind] || ""

    // A letter does what a click on its row does, as on the main panel. Holding one
    // down must not flip a tunnel back and forth. The long location list moves Vim-style.
    function pressKey(event) {
        const letter = event.text.toLowerCase();
        if (kind === "vpn") {
            const rows = { t: () => Sys.toggleTailscale(), m: () => Sys.toggleMullvad() };
            if (Sys.has("vpn"))
                rows.l = () => Ui.detail = "mullvad";
            if (!rows[letter])
                return false;
            if (!event.isAutoRepeat)
                rows[letter]();
            return true;
        }
        if (kind !== "mullvad")
            return false;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            const row = Sys.countries[locations.currentIndex];
            if (row && !event.isAutoRepeat)
                Sys.setMullvadCountry(row.code);
            return true;
        }
        const step = letter === "j" || event.key === Qt.Key_Down ? 1 : letter === "k" || event.key === Qt.Key_Up ? -1 : 0;
        if (!step)
            return false;
        locations.currentIndex = Math.max(0, Math.min(locations.count - 1, locations.currentIndex + step));
        locations.positionViewAtIndex(locations.currentIndex, ListView.Contain);
        // Enter belongs to the cursor now, not to a row reached with Tab.
        Ui.refocus();
        return true;
    }

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
                onClicked: Ui.back()
                Icon { anchors.centerIn: parent; name: "chevron-left"; size: 15 }
            }
            Label { Layout.fillWidth: true; text: root.title; font.weight: Font.DemiBold; font.pixelSize: 14 }
            KeyHint { Layout.rightMargin: 9; text: root.kind === "mullvad" ? "J K  Enter" : "" }
            Spinner {
                Layout.rightMargin: 9
                visible: Sys.scanning && (root.kind === "wifi" || root.kind === "bluetooth")
            }
        }

        // Wi-Fi
        Repeater {
            model: root.kind === "wifi" && Sys.state.wifi ? Sys.state.wifi.networks : []
            ColumnLayout {
                id: network
                required property var modelData
                readonly property bool enterprise: modelData.security.includes("802.1X")
                readonly property bool joining: Sys.joining === modelData.name
                readonly property bool needsPassword: !modelData.known && modelData.security !== ""
                Layout.fillWidth: true
                spacing: 0
                DetailRow {
                    Layout.fillWidth: true
                    name: network.modelData.name
                    title: network.modelData.name
                    note: network.joining ? "Joining…"
                        : network.modelData.active ? "Connected"
                        : network.needsPassword && network.enterprise ? "Needs setup"
                        : network.modelData.signal + "%"
                    locked: network.needsPassword
                    selected: network.modelData.active
                    busy: network.joining
                    // One join at a time, so the rest wait for it to finish.
                    opacity: Sys.joining === "" || network.joining ? 1 : 0.5
                    onClicked: {
                        if (network.modelData.active || Sys.joining !== "") return;
                        if (network.needsPassword && network.enterprise) {
                            Sys.openNetworkSettings();
                        } else if (network.needsPassword) {
                            root.asking = network.modelData.name;
                            password.ask();
                        } else {
                            Sys.joinWifi(network.modelData.name);
                        }
                    }
                }
                PasswordRow {
                    id: password
                    visible: root.asking === network.modelData.name
                    Layout.fillWidth: true
                    network: network.modelData.name
                    onCancelled: { root.asking = ""; Ui.refocus(); }
                    onSubmitted: value => { root.asking = ""; Ui.refocus(); Sys.joinWifi(network.modelData.name, value); }
                }
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "wifi-net" }
        DetailRow {
            visible: root.kind === "wifi"
            Layout.fillWidth: true
            Layout.topMargin: 4
            name: "Other networks"
            title: "Other Networks…"
            note: "Hidden, enterprise"
            onClicked: Sys.openNetworkSettings()
        }

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
        Label {
            visible: root.kind === "bluetooth" && Sys.btNearby.length > 0
            Layout.leftMargin: 10
            Layout.topMargin: 6
            text: "Nearby"
            font.pixelSize: 12
            color: Theme.dim
        }
        Repeater {
            model: root.kind === "bluetooth" ? Sys.btNearby : []
            DetailRow {
                required property var modelData
                Layout.fillWidth: true
                name: "Pair " + modelData.name
                title: modelData.name
                note: "Pair"
                busy: Sys.pending("bt-" + modelData.addr)
                onClicked: Sys.pairDevice(modelData)
            }
        }
        Repeater {
            model: root.kind === "bluetooth" ? Object.keys(Sys.writes).filter(k => k.startsWith("bt-") && Sys.failed(k)) : []
            FailRow { required property string modelData; Layout.fillWidth: true; writeKey: modelData }
        }

        // VPN
        DetailRow {
            visible: root.kind === "vpn"
            Layout.fillWidth: true
            name: "Tailscale"
            title: "Tailscale"
            hint: "T"
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
            hint: "M"
            note: Sys.mullvadOn ? "Connected" : "Off"
            selected: Sys.mullvadOn
            busy: Sys.pending("mullvad")
            onClicked: Sys.toggleMullvad()
        }
        FailRow { Layout.fillWidth: true; writeKey: "mullvad" }
        DetailRow {
            visible: root.kind === "vpn" && Sys.has("vpn")
            Layout.fillWidth: true
            name: "Mullvad location"
            title: "Mullvad location"
            hint: "L"
            note: (Sys.state.vpn && Sys.state.vpn.country || "").toUpperCase()
            onClicked: Ui.detail = "mullvad"
        }
        Label {
            visible: root.kind === "vpn" && root.exitNodes.length > 0
            Layout.leftMargin: 10
            Layout.topMargin: 6
            text: "Exit node"
            font.pixelSize: 12
            color: Theme.dim
        }
        Repeater {
            model: root.kind === "vpn" && root.exitNodes.length > 0 ? [""].concat(root.exitNodes) : []
            DetailRow {
                required property string modelData
                Layout.fillWidth: true
                name: "Exit node " + (modelData || "none")
                title: modelData || "None"
                selected: Sys.state.vpn.exitNode === modelData
                busy: Sys.pendingFor("exit-node", modelData)
                onClicked: Sys.setExitNode(modelData)
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "exit-node" }

        // Mullvad location. There are about fifty countries, so this one scrolls.
        ListView {
            id: locations
            visible: root.kind === "mullvad"
            Layout.fillWidth: true
            Layout.preferredHeight: 300
            clip: true
            model: root.kind === "mullvad" ? Sys.countries : []
            boundsBehavior: Flickable.StopAtBounds
            onModelChanged: currentIndex = 0
            delegate: DetailRow {
                required property var modelData
                width: ListView.view.width
                marked: ListView.isCurrentItem
                name: modelData.name
                title: modelData.name
                selected: Sys.state.vpn && Sys.state.vpn.country === modelData.code
                busy: Sys.pendingFor("mullvad-location", modelData.code)
                onClicked: Sys.setMullvadCountry(modelData.code)
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "mullvad-location" }

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
                busy: Sys.pendingFor("device-sink", modelData.name)
                onClicked: if (!modelData.active) Sys.setDefaultDevice("sink", modelData.name)
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "device-sink" }

        // Each playing app's own level. PipeWire applies these directly, so there is
        // nothing to confirm or retry, and the list follows streams as they come and go.
        // Volume is only readable while tracked, so track them while the view is open.
        readonly property var appStreams: root.kind === "sound" ? Sys.appStreams : []
        PwObjectTracker { objects: body.appStreams }
        Label { visible: body.appStreams.length > 0; Layout.leftMargin: 10; Layout.topMargin: 6; text: "Apps"; font.pixelSize: 12; color: Theme.dim }
        Repeater {
            model: body.appStreams
            RowLayout {
                id: app
                required property PwNode modelData
                readonly property string title: Sys.streamName(modelData)
                Layout.fillWidth: true
                Layout.leftMargin: 4
                Layout.rightMargin: 8
                spacing: 2
                Press {
                    implicitWidth: 28
                    implicitHeight: 28
                    radius: 14
                    name: (app.modelData.audio.muted ? "Unmute " : "Mute ") + app.title
                    onClicked: app.modelData.audio.muted = !app.modelData.audio.muted
                    Icon { anchors.centerIn: parent; name: app.modelData.audio.muted ? "volume-x" : "volume-2"; size: 14; color: app.modelData.audio.muted ? Theme.dim : Theme.text }
                }
                Label { Layout.preferredWidth: 92; text: app.title; elide: Text.ElideRight; font.pixelSize: 12; color: app.modelData.audio.muted ? Theme.dim : Theme.text }
                ThinSlider {
                    Layout.fillWidth: true
                    name: app.title + " volume"
                    level: Math.round(app.modelData.audio.volume * 100)
                    onChanged: value => app.modelData.audio.volume = value / 100
                }
            }
        }
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
                busy: Sys.pendingFor("device-source", modelData.name)
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
                busy: Sys.pendingFor("theme", modelData)
                onClicked: Sys.setTheme(modelData)
            }
        }
        FailRow { Layout.fillWidth: true; writeKey: "theme" }
        Label {
            visible: root.kind === "theme"
            Layout.leftMargin: 10
            Layout.topMargin: 10
            Layout.bottomMargin: 2
            text: "App icons"
            font.pixelSize: 11
            font.weight: Font.DemiBold
            color: Theme.dim
        }
        Repeater {
            model: root.kind === "theme" ? [{ mono: false, title: "Colour" }, { mono: true, title: "Monochrome", note: "Colour on hover" }] : []
            DetailRow {
                required property var modelData
                Layout.fillWidth: true
                name: modelData.title + " app icons"
                title: modelData.title
                note: modelData.note || ""
                selected: Theme.monoIcons === modelData.mono
                onClicked: Theme.monoIcons = modelData.mono
            }
        }
    }
}
