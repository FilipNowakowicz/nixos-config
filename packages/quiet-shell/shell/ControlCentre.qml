import QtQuick
import QtQuick.Layouts

// Floating pills with nothing behind them. Details take over the same space.
Item {
    id: root
    implicitWidth: 340
    implicitHeight: Ui.detail === "" ? grid.implicitHeight : details.implicitHeight
    Behavior on implicitHeight { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }

    ColumnLayout {
        id: grid
        width: parent.width
        spacing: 8
        visible: Ui.detail === ""

        RowLayout {
            spacing: 8
            ColumnLayout {
                spacing: 8
                Pill {
                    name: "Wi-Fi"
                    icon: Sys.wifiOn ? "wifi" : "wifi-off"
                    subtitle: !Sys.has("wifi") ? "Unavailable" : Sys.pending("wifi") ? "Working…" : (Sys.wifiOn ? (Sys.ssid || "Not connected") : "Off")
                    on: Sys.wifiOn
                    writeKey: "wifi"
                    detail: "wifi"
                    onToggle: Sys.toggleWifi()
                }
                Pill {
                    name: "Bluetooth"
                    icon: "bluetooth"
                    subtitle: {
                        if (!Sys.has("bluetooth")) return "Unavailable";
                        if (Sys.pending("bluetooth")) return "Working…";
                        if (!Sys.btOn) return "Off";
                        const d = Sys.btDevices.find(x => x.connected);
                        return d ? d.name : "On";
                    }
                    on: Sys.btOn
                    writeKey: "bluetooth"
                    detail: "bluetooth"
                    onToggle: Sys.toggleBluetooth()
                }
            }
            NowPlaying { Layout.preferredWidth: 166; Layout.preferredHeight: 132 }
        }
        RowLayout {
            spacing: 8
            Pill {
                name: "VPN"
                icon: "shield"
                subtitle: !Sys.has("vpn") ? "Unavailable" : (Sys.vpnOn ? [Sys.tailscaleOn ? "Tailscale" : "", Sys.mullvadOn ? "Mullvad" : ""].filter(x => x).join(" + ") : "Off")
                on: Sys.vpnOn
                writeKey: "tailscale"
                detail: "vpn"
                onToggle: Sys.toggleVpn()
            }
            Round { Layout.leftMargin: 7; name: "Keep awake"; icon: "coffee"; on: Sys.awake; writeKey: "awake"; onActivated: Sys.toggleAwake() }
            Item { Layout.fillWidth: true }
            Round { Layout.rightMargin: 7; name: "Night mode"; icon: "moon"; on: Sys.night; writeKey: "night"; onActivated: Sys.toggleNight() }
        }
        RowLayout {
            spacing: 8
            Pill {
                name: "Focus"
                icon: "bell-off"
                subtitle: Sys.focusMode ? "On" : "Off"
                on: Sys.focusMode
                onToggle: Sys.focusMode = !Sys.focusMode
            }
            Round { Layout.leftMargin: 7; name: "Theme"; icon: "palette"; onActivated: Ui.detail = "theme" }
            Item { Layout.fillWidth: true }
            Round { Layout.rightMargin: 7; name: "Microphone"; icon: Sys.micMuted ? "mic-off" : "mic"; writeKey: "mic-mute"; onActivated: Sys.toggleMicMute() }
        }
        Repeater {
            model: ["wifi", "bluetooth", "tailscale", "mullvad", "night", "awake", "mute", "mic-mute"]
            FailRow { required property string modelData; Layout.fillWidth: true; writeKey: modelData }
        }
        LevelModule {
            Layout.fillWidth: true
            title: "Sound"
            sliderName: "Volume"
            icon: Sys.muted ? "volume-x" : "volume-2"
            level: Sys.volume
            detail: "sound"
            mutable: true
            onMoved: value => Sys.setLevel("sink", value)
            onMute: Sys.toggleMute()
        }
        LevelModule {
            Layout.fillWidth: true
            title: "Display"
            sliderName: "Brightness"
            icon: "sun"
            endIcon: "sun"
            level: Sys.brightness
            onMoved: value => Sys.setLevel("brightness", value)
        }
    }

    DetailView {
        id: details
        width: parent.width
        visible: Ui.detail !== ""
    }
}
