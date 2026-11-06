pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// System state and writes. A write is only "done" once a fresh readback shows the
// target. Until then the key is pending, and if it never shows, it fails with Retry.
Singleton {
    id: root

    property var state: ({})
    property var writes: ({})
    property bool focusMode: false
    readonly property int failedCount: Object.keys(writes).filter(k => writes[k].status === "failed").length

    readonly property bool wifiOn: state.wifi ? state.wifi.on : false
    readonly property string ssid: state.wifi ? state.wifi.ssid : ""
    readonly property bool btOn: state.bluetooth ? state.bluetooth.on : false
    readonly property var btDevices: state.bluetooth ? state.bluetooth.devices : []
    readonly property bool tailscaleOn: state.vpn ? state.vpn.tailscale : false
    readonly property bool mullvadOn: state.vpn ? state.vpn.mullvad : false
    readonly property bool vpnOn: tailscaleOn || mullvadOn
    readonly property int volume: state.sink ? state.sink.level : 0
    readonly property bool muted: state.sink ? state.sink.muted : false
    readonly property int micLevel: state.source ? state.source.level : 0
    readonly property bool micMuted: state.source ? state.source.muted : false
    readonly property int brightness: state.brightness === undefined || state.brightness === null ? 0 : state.brightness
    readonly property string profile: state.profile || "balanced"
    readonly property var battery: state.battery || null
    readonly property var media: state.media || null
    readonly property bool night: !!state.night
    readonly property bool awake: !!state.awake

    function has(section) { return state[section] !== undefined && state[section] !== null; }
    function pending(key) { return !!(writes[key] && writes[key].status === "pending"); }
    function failed(key) { return !!(writes[key] && writes[key].status === "failed"); }
    function failMessage(key) { return writes[key] ? writes[key].message : ""; }

    function setWrite(key, value) {
        const next = Object.assign({}, writes);
        if (value)
            next[key] = value;
        else
            delete next[key];
        writes = next;
    }

    // `done(state)` decides from a fresh snapshot whether the write took effect.
    function write(key, command, done, message) {
        if (pending(key))
            return;
        setWrite(key, { status: "pending", command, done, message, deadline: Date.now() + 8000 });
        const proc = runner.createObject(root, { command, key });
        proc.running = true;
    }

    function retry(key) {
        const w = writes[key];
        if (!w)
            return;
        setWrite(key, null);
        write(key, w.command, w.done, w.message);
    }

    function dismiss(key) { setWrite(key, null); }

    function reconcile() {
        for (const key of Object.keys(writes)) {
            const w = writes[key];
            if (w.status !== "pending")
                continue;
            // The deadline also covers a command that hung or could not start at all.
            if (w.exited && w.done(state))
                setWrite(key, null);
            else if (Date.now() > w.deadline)
                setWrite(key, Object.assign({}, w, { status: "failed" }));
        }
    }

    function refresh() {
        if (!status.running)
            status.running = true;
    }

    Component {
        id: runner
        Process {
            property string key
            onExited: code => {
                const w = root.writes[key];
                if (w) {
                    if (code !== 0)
                        root.setWrite(key, Object.assign({}, w, { status: "failed" }));
                    else
                        root.setWrite(key, Object.assign({}, w, { exited: true }));
                }
                root.refresh();
                destroy();
            }
        }
    }

    // A slider drag sends many writes; only the latest level matters.
    property var levelTargets: ({})
    function setLevel(kind, value) {
        levelTargets[kind] = Math.round(value);
        levelTimer.restart();
    }
    Timer {
        id: levelTimer
        interval: 60
        onTriggered: {
            for (const kind of Object.keys(root.levelTargets)) {
                const v = root.levelTargets[kind];
                if (kind === "brightness")
                    Quickshell.execDetached(["brightnessctl", "set", Math.max(1, v) + "%"]);
                else
                    Quickshell.execDetached(["wpctl", "set-volume", kind === "sink" ? "@DEFAULT_AUDIO_SINK@" : "@DEFAULT_AUDIO_SOURCE@", (v / 100).toFixed(2)]);
            }
            root.levelTargets = {};
            settle.restart();
        }
    }
    Timer { id: settle; interval: 250; onTriggered: root.refresh() }

    function toggleWifi() {
        const want = !wifiOn;
        write("wifi", ["nmcli", "radio", "wifi", want ? "on" : "off"], s => s.wifi && s.wifi.on === want, "Wi-Fi didn't turn " + (want ? "on." : "off."));
    }
    function joinWifi(name) {
        write("wifi-net", ["nmcli", "dev", "wifi", "connect", name], s => s.wifi && s.wifi.ssid === name, "Couldn't join " + name + ".");
    }
    function toggleBluetooth() {
        const want = !btOn;
        write("bluetooth", ["bluetoothctl", "power", want ? "on" : "off"], s => s.bluetooth && s.bluetooth.on === want, "Bluetooth didn't turn " + (want ? "on." : "off."));
    }
    function toggleDevice(dev) {
        const want = !dev.connected;
        write("bt-" + dev.addr, ["bluetoothctl", want ? "connect" : "disconnect", dev.addr],
            s => s.bluetooth && s.bluetooth.devices.some(d => d.addr === dev.addr && d.connected === want),
            "Couldn't " + (want ? "connect " : "disconnect ") + dev.name + ".");
    }
    function toggleTailscale() {
        const want = !tailscaleOn;
        write("tailscale", ["tailscale", want ? "up" : "down"], s => s.vpn && s.vpn.tailscale === want, "Tailscale didn't change.");
    }
    function toggleMullvad() {
        const want = !mullvadOn;
        write("mullvad", ["mullvad", want ? "connect" : "disconnect"], s => s.vpn && s.vpn.mullvad === want, "Mullvad didn't change.");
    }
    function toggleVpn() {
        if (vpnOn) {
            if (tailscaleOn) toggleTailscale();
            if (mullvadOn) toggleMullvad();
        } else {
            toggleTailscale();
        }
    }
    function toggleMute() {
        const want = !muted;
        write("mute", ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", want ? "1" : "0"], s => s.sink && s.sink.muted === want, "Mute didn't change.");
    }
    function toggleMicMute() {
        const want = !micMuted;
        write("mic-mute", ["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", want ? "1" : "0"], s => s.source && s.source.muted === want, "Microphone didn't change.");
    }
    function setDefaultDevice(role, name) {
        const key = "default.configured.audio." + role;
        const list = role === "sink" ? "sinks" : "sources";
        write("device-" + role, ["pw-metadata", "-n", "default", "0", key, JSON.stringify({ name })],
            s => s.devices && s.devices[list].some(d => d.name === name && d.active), "The device didn't change.");
    }
    function setProfile(name) {
        write("profile", ["powerprofilesctl", "set", name], s => s.profile === name, "Power mode didn't change.");
    }
    function toggleNight() {
        const want = !night;
        const cmd = want ? ["sh", "-c", "setsid -f wlsunset -l 52.2 -L 21.0 >/dev/null 2>&1"] : ["pkill", "-x", "wlsunset"];
        write("night", cmd, s => !!s.night === want, "Night mode didn't change.");
    }
    function toggleAwake() {
        const want = !awake;
        const cmd = want
            ? ["systemd-run", "--user", "--unit=caffeinate.service", "--collect", "systemd-inhibit", "--what=handle-lid-switch:idle", "--who=quiet-shell", "--why=Keep awake", "sleep", "infinity"]
            : ["systemctl", "--user", "stop", "caffeinate.service"];
        write("awake", cmd, s => !!s.awake === want, "Keep awake didn't change.");
    }
    function setTheme(name) {
        write("theme", ["theme-switch", name], () => Theme.name === name, "The theme didn't change.");
    }
    function mediaCommand(verb) {
        Quickshell.execDetached(["playerctl", verb]);
        settle.restart();
    }

    Process {
        id: status
        command: ["python3", Qt.resolvedUrl("scripts/status.py").toString().replace("file://", "")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.state = JSON.parse(text);
                    root.reconcile();
                } catch (e) {
                    console.warn("quiet-shell: bad status output", e);
                }
            }
        }
    }

    property bool live: false
    Timer {
        interval: Object.keys(root.writes).length ? 700 : (root.live ? 4000 : 60000)
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
    onLiveChanged: if (live) refresh()
}
