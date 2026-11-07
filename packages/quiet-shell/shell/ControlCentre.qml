import QtQuick
import QtQuick.Layouts

// Floating pills with nothing behind them. Details take over the same space.
Item {
    id: root
    implicitWidth: 340
    implicitHeight: Ui.detail === "" ? grid.implicitHeight : details.implicitHeight
    Behavior on implicitHeight { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
    onVisibleChanged: if (visible) Sys.refreshBuds()

    // A letter does what a click on that control's pill does. Wi-Fi and VPN open their
    // details rather than switching, so a stray key can't drop the connection.
    function pressLetter(letter) {
        const actions = {
            b: () => Sys.toggleBuds(),
            w: () => Ui.detail = "wifi",
            v: () => Ui.detail = "vpn",
            t: () => Ui.detail = "theme",
            f: () => Sys.focusMode = !Sys.focusMode,
            n: () => Sys.toggleNight(),
            a: () => Sys.toggleAwake(),
            m: () => Sys.toggleMute()
        };
        if (!actions[letter])
            return false;
        actions[letter]();
        return true;
    }

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
                    hint: "W"
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
                hint: "V"
                icon: "shield"
                subtitle: !Sys.has("vpn") ? "Unavailable" : (Sys.vpnOn ? [Sys.tailscaleOn ? "Tailscale" : "", Sys.mullvadOn ? "Mullvad" : ""].filter(x => x).join(" + ") : "Off")
                on: Sys.vpnOn
                writeKey: "tailscale"
                detail: "vpn"
                onToggle: Sys.toggleVpn()
            }
            Round { Layout.leftMargin: 7; name: "Keep awake"; hint: "A"; icon: "coffee"; on: Sys.awake; writeKey: "awake"; onActivated: Sys.toggleAwake() }
            Item { Layout.fillWidth: true }
            Round { Layout.rightMargin: 7; name: "Night mode"; hint: "N"; icon: "moon"; on: Sys.night; writeKey: "night"; onActivated: Sys.toggleNight() }
        }
        RowLayout {
            spacing: 8
            Pill {
                name: "Focus"
                hint: "F"
                icon: "bell-off"
                subtitle: Sys.focusMode ? "On" : "Off"
                on: Sys.focusMode
                onToggle: Sys.focusMode = !Sys.focusMode
            }
            Pill {
                name: "Theme"
                hint: "T"
                icon: "palette"
                subtitle: Theme.name.split("-").map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(" ")
                detail: "theme"
                toggles: false
            }
        }
        Repeater {
            // Every failure, so the warning in the top bar always leads somewhere.
            model: Object.keys(Sys.writes).filter(k => Sys.failed(k))
            FailRow { required property string modelData; Layout.fillWidth: true; writeKey: modelData }
        }
        LevelModule {
            Layout.fillWidth: true
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
            sliderName: "Brightness"
            icon: "sun"
            endIcon: "sun"
            level: Sys.brightness
            onMoved: value => Sys.setLevel("brightness", value)
        }
        BudsCard { Layout.fillWidth: true }
    }

    DetailView {
        id: details
        width: parent.width
        visible: Ui.detail !== ""
    }
}
