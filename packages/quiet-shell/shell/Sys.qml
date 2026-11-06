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
    onFocusModeChanged: if (focusFile.loaded) focusFile.setText(focusMode ? "on" : "off")
    readonly property int failedCount: Object.keys(writes).filter(k => writes[k].status === "failed").length

    readonly property bool wifiOn: state.wifi ? state.wifi.on : false
    readonly property string ssid: state.wifi ? state.wifi.ssid : ""
    readonly property bool btOn: state.bluetooth ? state.bluetooth.on : false
    readonly property var btDevices: state.bluetooth ? state.bluetooth.devices : []
    readonly property var btNearby: state.bluetooth ? state.bluetooth.nearby : []
    readonly property bool tailscaleOn: state.vpn ? state.vpn.tailscale : false
    readonly property bool mullvadOn: state.vpn ? state.vpn.mullvad : false
    readonly property bool vpnOn: tailscaleOn || mullvadOn
    readonly property int volume: state.sink ? state.sink.level : 0
    readonly property bool muted: state.sink ? state.sink.muted : false
    readonly property int micLevel: state.source ? state.source.level : 0
    readonly property int brightness: state.brightness === undefined || state.brightness === null ? 0 : state.brightness
    readonly property string profile: state.profile || "balanced"
    readonly property var battery: state.battery || null
    readonly property var media: state.media || null
    readonly property bool night: !!state.night
    readonly property bool awake: !!state.awake

    // Warn once per discharge at each threshold, and again after charging.
    property int warnedAt: 100
    onBatteryChanged: {
        if (!battery) return;
        if (battery.charging) {
            warnedAt = 100;
            return;
        }
        for (const limit of [5, 15]) {
            if (battery.level <= limit && limit < warnedAt) {
                warnedAt = limit;
                Notify.post("Battery low", battery.level + "% left. Plug in soon.", limit === 5);
                break;
            }
        }
    }

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
    // options: `input` goes to stdin so it never shows in the process list, `timeout`
    // is for slow actions, and `undo` runs if the command fails.
    function write(key, command, done, message, options) {
        if (pending(key))
            return;
        const o = options || {};
        setWrite(key, { status: "pending", command, done, message, options: o, deadline: Date.now() + (o.timeout || 8000) });
        const proc = runner.createObject(root, { command, key, input: o.input || "" });
        proc.running = true;
    }

    function retry(key) {
        const w = writes[key];
        if (!w)
            return;
        setWrite(key, null);
        write(key, w.command, w.done, w.message, w.options);
    }

    function dismiss(key) { setWrite(key, null); }

    function reconcile() {
        for (const key of Object.keys(writes)) {
            const w = writes[key];
            // A failed setting that later reaches its target has healed itself.
            if (w.status === "failed") {
                if (w.done(state))
                    setWrite(key, null);
                continue;
            }
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
            property string input
            stdinEnabled: input !== ""
            onStarted: if (input !== "") { write(input); stdinEnabled = false; }
            onExited: code => {
                const w = root.writes[key];
                if (w) {
                    if (code !== 0) {
                        root.setWrite(key, Object.assign({}, w, { status: "failed" }));
                        if (w.options.undo)
                            Quickshell.execDetached(w.options.undo);
                    } else
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
    function joinWifi(name, password) {
        const secret = !!password;
        write("wifi-net", ["nmcli"].concat(secret ? ["--ask"] : [], ["dev", "wifi", "connect", name]),
            s => s.wifi && s.wifi.ssid === name,
            secret ? "Couldn't join. Wrong password?" : "Couldn't join " + name + ".",
            // A failed attempt leaves a profile behind that would look like a saved network.
            secret ? { input: password + "\n", timeout: 30000, undo: ["nmcli", "connection", "delete", "id", name] } : { timeout: 30000 });
    }
    function rescanWifi() {
        Quickshell.execDetached(["nmcli", "dev", "wifi", "rescan"]);
    }
    function scanBluetooth() {
        Quickshell.execDetached(["bluetoothctl", "--timeout", "15", "scan", "on"]);
    }
    function pairDevice(dev) {
        write("bt-" + dev.addr,
            ["sh", "-c", 'bluetoothctl --agent NoInputNoOutput pair "$0" && bluetoothctl trust "$0" && bluetoothctl connect "$0"', dev.addr],
            s => s.bluetooth && s.bluetooth.devices.some(d => d.addr === dev.addr && d.connected),
            "Couldn't pair " + dev.name + ".", { timeout: 30000 });
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
    // The hardware keys. They read the result straight back, because a pop-up that
    // waits for a full status read feels broken.
    function nudge(kind, command) {
        if (nudger.running) {
            nudger.queued = [kind, command];
            return;
        }
        nudger.kind = kind;
        nudger.command = command;
        nudger.running = true;
    }
    function nudgeVolume(step) {
        const delta = Math.abs(step) + "%" + (step < 0 ? "-" : "+");
        nudge("volume", ["sh", "-c", 'wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ "$0" && wpctl get-volume @DEFAULT_AUDIO_SINK@', delta]);
    }
    function nudgeMute() {
        nudge("volume", ["sh", "-c", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && wpctl get-volume @DEFAULT_AUDIO_SINK@"]);
    }
    function nudgeBrightness(step) {
        nudge("brightness", ["brightnessctl", "-m", "set", Math.abs(step) + "%" + (step < 0 ? "-" : "+")]);
    }
    Process {
        id: nudger
        property string kind
        property var queued: null
        stdout: StdioCollector {
            onStreamFinished: {
                if (nudger.kind === "volume") {
                    const match = text.match(/([0-9.]+)/);
                    if (match)
                        Ui.showHud("volume", Math.round(parseFloat(match[1]) * 100), text.includes("[MUTED]"));
                } else {
                    const match = text.match(/(\d+)%/);
                    if (match)
                        Ui.showHud("brightness", parseInt(match[1]), false);
                }
                settle.restart();
            }
        }
        onExited: {
            if (queued) {
                const next = queued;
                queued = null;
                root.nudge(next[0], next[1]);
            }
        }
    }

    function screenshot(mode) {
        Ui.close();
        capture.command = ["python3", Qt.resolvedUrl("scripts/screenshot.py").toString().replace("file://", ""), mode];
        captureDelay.restart();
    }
    // The bar has to fade away before the picture is taken.
    Timer {
        id: captureDelay
        interval: Theme.motion + 90
        onTriggered: capture.running = true
    }
    Process {
        id: capture
        stdout: StdioCollector {
            onStreamFinished: {
                const path = text.trim();
                if (path)
                    Notify.post("Screenshot saved", "Copied to the clipboard", false, path);
            }
        }
        onExited: code => { if (code !== 0) Notify.post("Screenshot failed", "Nothing was saved.", false); }
    }

    property var weather: null
    property real weatherAt: 0
    // Called when the centre opens. A forecast barely moves in half an hour.
    function refreshWeather() {
        if (!weatherRead.running && Date.now() - weatherAt > 1800000)
            weatherRead.running = true;
    }
    Process {
        id: weatherRead
        command: ["python3", Qt.resolvedUrl("scripts/weather.py").toString().replace("file://", "")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.weather = JSON.parse(text);
                    root.weatherAt = Date.now();
                } catch (e) {
                    // Keep the last reading. The card hides if there has never been one.
                }
            }
        }
    }

    function setMullvadCountry(code) {
        write("mullvad-location", ["mullvad", "relay", "set", "location", code], s => s.vpn && s.vpn.country === code, "Mullvad's location didn't change.", { timeout: 15000 });
    }
    function setExitNode(name) {
        write("exit-node", ["tailscale", "set", "--exit-node=" + name], s => s.vpn && s.vpn.exitNode === name, "The exit node didn't change.", { timeout: 15000 });
    }
    function openNetworkSettings() {
        Ui.close();
        Quickshell.execDetached(["nm-connection-editor"]);
    }
    property var countries: []
    function loadCountries() {
        if (!countryList.running)
            countryList.running = true;
    }
    Process {
        id: countryList
        command: ["python3", Qt.resolvedUrl("scripts/status.py").toString().replace("file://", ""), "countries"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.countries = JSON.parse(text);
                } catch (e) {
                    root.countries = [];
                }
            }
        }
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
        const location = Qt.resolvedUrl("scripts/location.py").toString().replace("file://", "");
        const cmd = want ? ["sh", "-c", 'where=$(python3 "$0") && setsid -f wlsunset $where >/dev/null 2>&1', location] : ["pkill", "-x", "wlsunset"];
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

    FileView {
        id: focusFile
        property bool loaded: false
        path: Quickshell.env("HOME") + "/.local/state/quiet-shell/focus"
        printErrors: false
        onLoaded: { root.focusMode = text().trim() === "on"; loaded = true; }
        onLoadFailed: loaded = true
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
