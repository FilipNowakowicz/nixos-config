import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The launcher. A leading > runs the rest as a command.
Item {
    id: root
    implicitWidth: 640
    implicitHeight: 62 + (list.visible ? list.implicitHeight + 10 : 0) + (suggestions.visible ? 96 : 0) + (none.visible ? 44 : 0)

    property int selected: 0
    readonly property string query: input.text.trim()
    readonly property var apps: DesktopEntries.applications.values.filter(a => !a.noDisplay).slice().sort((a, b) => a.name.localeCompare(b.name))

    function score(text, q) {
        const t = text.toLowerCase();
        if (t === q) return 0;
        if (t.startsWith(q)) return 1;
        return t.includes(q) ? 2 : -1;
    }
    readonly property bool clipboardMode: Ui.clipboard

    function calculate(text) {
        if (!/^[\d\s+\-*\/().,%^]+$/.test(text) || !/\d/.test(text) || !/[+\-*\/%^(]/.test(text))
            return null;
        const source = text.replace(/,/g, ".").replace(/\^/g, "**").replace(/([\d.]+)%/g, "($1/100)");
        try {
            const value = new Function("return (" + source + ");")();
            return Number.isFinite(value) ? String(+value.toFixed(10)) : null;
        } catch (e) {
            return null;
        }
    }
    readonly property var actions: [
        { title: "Lock Screen", note: "Run", run: () => Ui.session("lock") },
        { title: "Sleep", note: "Run", run: () => Ui.session("sleep") },
        { title: "Restart…", note: "Run", run: () => Ui.session("restart") },
        { title: "Shut Down…", note: "Run", run: () => Ui.session("shutdown") },
        { title: "Log Out…", note: "Run", run: () => Ui.session("logout") },
        { title: "Focus", note: Sys.focusMode ? "Turn off" : "Turn on", run: () => { Sys.focusMode = !Sys.focusMode; Ui.close(); } },
        { title: "Night Mode", note: Sys.night ? "Turn off" : "Turn on", run: () => { Sys.toggleNight(); Ui.close(); } },
        { title: "Keep Awake", note: Sys.awake ? "Turn off" : "Turn on", run: () => { Sys.toggleAwake(); Ui.close(); } },
        { title: "Wi-Fi", note: Sys.wifiOn ? "Turn off" : "Turn on", run: () => { Sys.toggleWifi(); Ui.close(); } },
        { title: "Bluetooth", note: Sys.btOn ? "Turn off" : "Turn on", run: () => { Sys.toggleBluetooth(); Ui.close(); } }
    ]
    property var clips: []
    property var files: []

    readonly property var results: {
        if (clipboardMode) {
            const wanted = query.toLowerCase();
            return clips.filter(c => c.text.toLowerCase().includes(wanted)).slice(0, 8)
                .map(c => ({ group: "Clipboard", title: c.text, note: "Copy", kind: "clip", value: c.line, glyph: "clipboard" }));
        }
        if (query === "") return [];
        if (query.startsWith(">")) {
            const cmd = query.slice(1).trim();
            return [{ group: "Command", title: cmd || "Type a command", note: "Run", kind: "command", value: cmd }];
        }
        const q = query.toLowerCase();
        const answer = calculate(query);
        const sums = answer === null ? [] : [{ group: "Calculator", title: answer, note: "Copy", kind: "copy", value: answer, glyph: "calculator" }];
        const found = apps.map(a => ({ a, s: score(a.name, q) })).filter(x => x.s >= 0)
            .sort((x, y) => x.s - y.s).slice(0, 4)
            .map(x => ({ group: "Applications", title: x.a.name, note: "Open", kind: "app", value: x.a, icon: x.a.icon }));
        const windows = ToplevelManager.toplevels.values
            .filter(t => (t.title + " " + t.appId).toLowerCase().includes(q)).slice(0, 3)
            .map(t => ({ group: "Open windows", title: t.title || t.appId, note: "Switch", kind: "window", value: t }));
        const system = actions.filter(a => score(a.title, q) >= 0).slice(0, 3)
            .map(a => ({ group: "System", title: a.title, note: a.note, kind: "action", value: a.run, glyph: "power" }));
        const inFiles = files.map(f => ({ group: "Files", title: f.name, note: f.folder, kind: "file", value: f.path, glyph: "folder" }));
        const web = answer === null ? [{ group: "Web", title: "Search the web for " + query, note: "Open", kind: "web", value: query, glyph: "globe" }] : [];
        return sums.concat(found, windows, system, inFiles, web);
    }
    onQueryChanged: {
        files = [];
        fileSearch.running = false;
        if (query.length >= 3 && !query.startsWith(">") && !clipboardMode)
            fileDelay.restart();
    }
    onClipboardModeChanged: if (clipboardMode) clipList.running = true

    Timer {
        id: fileDelay
        interval: 180
        onTriggered: {
            fileSearch.command = ["fd", "--type", "f", "--fixed-strings", "--max-results", "3", "--color", "never", "--", root.query, Quickshell.env("HOME")];
            fileSearch.running = true;
        }
    }
    Process {
        id: fileSearch
        stdout: StdioCollector {
            onStreamFinished: {
                const home = Quickshell.env("HOME");
                root.files = text.split("\n").filter(p => p).map(path => {
                    const at = path.lastIndexOf("/");
                    return { path, name: path.slice(at + 1), folder: path.slice(0, at).replace(home, "~") };
                });
            }
        }
    }
    Process {
        id: clipList
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.clips = text.split("\n").filter(l => l.includes("\t")).map(line => ({ line, text: line.slice(line.indexOf("\t") + 1) }));
            }
        }
    }

    onResultsChanged: selected = Math.min(selected, Math.max(results.length - 1, 0))

    function launch(item) {
        if (!item) return;
        if (item.kind === "app") item.value.execute();
        if (item.kind === "window") Dockable.revealWayland(item.value);
        if (item.kind === "command" && item.value) Quickshell.execDetached(["sh", "-c", item.value]);
        if (item.kind === "copy") Quickshell.execDetached(["wl-copy", item.value]);
        if (item.kind === "clip") Quickshell.execDetached(["sh", "-c", 'printf "%s" "$0" | cliphist decode | wl-copy', item.value]);
        if (item.kind === "file") Quickshell.execDetached(["xdg-open", item.value]);
        if (item.kind === "web") Quickshell.execDetached(["xdg-open", "https://duckduckgo.com/?q=" + encodeURIComponent(item.value)]);
        // These decide for themselves what stays open.
        if (item.kind === "action") item.value();
        else Ui.close();
    }

    onVisibleChanged: if (visible) { input.text = ""; selected = 0; input.forceActiveFocus(); }

    MouseArea { anchors.fill: parent }
    Glass { anchors.fill: parent; radius: 31 }

    RowLayout {
        id: bar
        x: 24
        width: parent.width - 48
        height: 62
        spacing: 14
        Icon { name: root.clipboardMode ? "clipboard" : "search"; size: 21; color: Theme.dim }
        TextInput {
            id: input
            Layout.fillWidth: true
            color: Theme.text
            selectionColor: Theme.fillHover
            font.family: Theme.font
            font.pixelSize: 22
            activeFocusOnTab: true
            Accessible.name: "Search"
            Accessible.role: Accessible.EditableText
            Keys.onDownPressed: root.selected = root.results.length ? (root.selected + 1) % root.results.length : 0
            Keys.onUpPressed: root.selected = root.results.length ? (root.selected + root.results.length - 1) % root.results.length : 0
            Keys.onEscapePressed: Ui.close()
            onAccepted: root.launch(root.results[root.selected])
            Label {
                visible: input.text === ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.clipboardMode ? "Search clipboard history" : "Search apps, files and settings"
                font.pixelSize: 22
                color: Theme.dim
            }
        }
    }

    RowLayout {
        id: suggestions
        visible: root.query === "" && !root.clipboardMode
        y: 62
        x: 14
        width: parent.width - 28
        height: 84
        spacing: 4
        Repeater {
            model: Dockable.suggested
            Press {
                required property var modelData
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 16
                name: modelData.name
                onClicked: { modelData.launch(); Ui.close(); }
                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; size: 44; icon: modelData.icon; fallback: modelData.name }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.name; font.pixelSize: 11 }
                }
            }
        }
    }

    Label {
        id: none
        visible: root.query !== "" && root.results.length === 0
        x: 24
        y: 62
        height: 34
        text: "No results for " + root.query
        color: Theme.dim
    }

    ColumnLayout {
        id: list
        visible: root.results.length > 0
        y: 62
        x: 10
        width: parent.width - 20
        spacing: 0
        Repeater {
            model: root.results
            ColumnLayout {
                id: rowItem
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: 0
                Label {
                    visible: rowItem.index === 0 || root.results[rowItem.index - 1].group !== rowItem.modelData.group
                    Layout.leftMargin: 14
                    Layout.topMargin: 6
                    text: rowItem.modelData.group
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    color: Theme.dim
                }
                Press {
                    Layout.fillWidth: true
                    implicitHeight: 46
                    radius: 14
                    name: rowItem.modelData.title
                    rest: rowItem.index === root.selected ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.26) : "transparent"
                    hover: rest
                    onClicked: root.launch(rowItem.modelData)
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 14
                        spacing: 12
                        AppIcon { size: 30; icon: rowItem.modelData.icon || ""; fallback: rowItem.modelData.title; glyph: rowItem.modelData.kind === "command" ? "terminal" : rowItem.modelData.glyph || "" }
                        Label { Layout.fillWidth: true; text: rowItem.modelData.title; font.pixelSize: 14 }
                        Label { Layout.maximumWidth: 220; text: rowItem.modelData.note; font.pixelSize: 12; color: Theme.dim }
                    }
                }
            }
        }
    }
}
