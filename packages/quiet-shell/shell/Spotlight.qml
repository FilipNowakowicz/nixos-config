import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Search.js" as Search

// The launcher. A leading > runs the rest as a command. It learns what you pick,
// so the same few letters and Enter keep doing what you meant.
Item {
    id: root
    implicitWidth: 640
    implicitHeight: 62 + (list.visible ? list.implicitHeight + 10 : 0) + (none.visible ? 44 : 0)

    property int selected: 0
    readonly property string query: input.text.trim()
    readonly property var apps: DesktopEntries.applications.values.filter(a => !a.noDisplay).slice().sort((a, b) => a.name.localeCompare(b.name))
    readonly property bool clipboardMode: Ui.clipboard
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/quiet-shell"

    readonly property var actions: [
        { title: "Lock Screen", note: "Run", run: () => Ui.session("lock") },
        { title: "Sleep", note: "Run", run: () => Ui.session("sleep") },
        { title: "Restart", note: "Run", run: () => Ui.session("restart") },
        { title: "Shut Down", note: "Run", run: () => Ui.session("shutdown") },
        { title: "Log Out", note: "Run", run: () => Ui.session("logout") },
        { title: "Focus", note: Sys.focusMode ? "Turn off" : "Turn on", run: () => { Sys.focusMode = !Sys.focusMode; Ui.close(); } },
        { title: "Night Mode", note: Sys.night ? "Turn off" : "Turn on", run: () => { Sys.toggleNight(); Ui.close(); } },
        { title: "Keep Awake", note: Sys.awake ? "Turn off" : "Turn on", run: () => { Sys.toggleAwake(); Ui.close(); } },
        { title: "Wi-Fi", note: Sys.wifiOn ? "Turn off" : "Turn on", run: () => { Sys.toggleWifi(); Ui.close(); } },
        { title: "Bluetooth", note: Sys.btOn ? "Turn off" : "Turn on", run: () => { Sys.toggleBluetooth(); Ui.close(); } },
        { title: "Mullvad", note: Sys.mullvadOn ? "Disconnect" : "Connect", run: () => { Sys.toggleMullvad(); Ui.close(); } },
        { title: "Mullvad Location", note: (Sys.state.vpn && Sys.state.vpn.country || "").toUpperCase() || "Choose", run: () => { input.text = "mullvad "; } },
        { title: "Location", note: Sys.place ? Sys.place.name : Sys.timezone || "Choose", run: () => { input.text = "location "; } },
        { title: "Notes", note: "Open", run: () => { Ui.close(); Sys.openNotes(); } }
    ]
    // Towns of 15,000 people or more (GeoNames), biggest first, found by name, region
    // or country: "location krakow", "location poland". Picking one sets the clock's
    // zone and puts the weather and Night mode there. Read the first time it's asked.
    property bool citiesWanted: false
    property var cities: []
    property var countries: ({})
    property var zoneCountry: ({})
    // Names people type that the country list spells differently.
    readonly property var countryAliases: ({ GB: "uk england scotland wales britain", US: "usa america", AE: "uae", NL: "holland", CZ: "czechia", KR: "korea", KP: "korea" })
    FileView {
        path: root.citiesWanted ? Qt.resolvedUrl("data/cities.tsv").toString().replace("file://", "") : ""
        printErrors: false
        onLoaded: root.cities = text().split("\n").filter(l => l).map(l => {
            const f = l.split("\t");
            return { name: f[0], plain: f[1], country: f[2], region: f[3], lat: f[5], lon: f[6], zone: f[7] };
        })
    }
    // Each town's search words, once both lists are in.
    readonly property var cityWords: cities.map(c => [c.name, c.plain, c.region, countries[c.country] || "", countryAliases[c.country] || ""]
        .join(" ").replace(/[(),]/g, " ").toLowerCase().split(/[\s\-_.:']+/).filter(w => w))
    FileView {
        path: Quickshell.env("QUIET_COUNTRY_TAB") || ""
        printErrors: false
        onLoaded: {
            const names = {};
            for (const line of text().split("\n")) {
                const f = line.split("\t");
                if (line && !line.startsWith("#") && f.length > 1)
                    names[f[0]] = f[1];
            }
            root.countries = names;
        }
    }
    // Which country a zone belongs to, so an empty search lists the towns near the clock.
    FileView {
        path: Quickshell.env("QUIET_ZONE_TAB") || ""
        printErrors: false
        onLoaded: {
            const map = {};
            for (const line of text().split("\n")) {
                const f = line.split("\t");
                if (line && !line.startsWith("#") && f.length > 2)
                    map[f[2]] = f[0].split(",")[0];
            }
            root.zoneCountry = map;
        }
    }
    function cityResults(wanted) {
        citiesWanted = true;
        const parts = wanted.toLowerCase().split(/\s+/).filter(p => p);
        const here = zoneCountry[Sys.timezone] || "";
        const found = [];
        const named = [];  // Towns whose own name starts with the words come first.
        for (let i = 0; i < cities.length && named.length < 8; i++) {
            const c = cities[i];
            const hit = parts.length
                ? parts.every(p => cityWords[i].some(w => w.startsWith(p)))
                : c.country === here;
            if (!hit)
                continue;
            const name = (c.name + " " + c.plain).toLowerCase();
            if (parts.length && name.split(/[\s\-']+/).some(w => w.startsWith(parts[0])))
                named.push(c);
            else if (found.length < 8)
                found.push(c);
        }
        return named.concat(found).slice(0, 8).map(c => {
            const current = Sys.place !== null && Sys.place.name === c.name && Sys.place.zone === c.zone;
            return {
                group: "Location",
                title: c.name,
                note: [c.region, countries[c.country] || c.country].filter(t => t && t !== c.name).join(", ") + " · " + (current ? "Current" : "Set"),
                kind: "action",
                value: () => { if (!current) Sys.setLocation(c); Ui.close(); },
                glyph: "globe"
            };
        });
    }
    property var clips: []
    property var files: []
    property var memory: ({ picks: {}, typed: {} })
    property var rates: null

    function used(key) {
        return Search.frecency(memory.picks[key], Date.now());
    }
    // The name counts most, then what the app is (a "Web Browser") and its keywords.
    function appScore(a, q) {
        const s = Search.score(a.name, q);
        if (s >= 0 && s <= 2) return s;
        const extra = [a.genericName].concat(Array.from(a.keywords || [])).filter(k => k);
        return extra.some(k => Search.wordsMatch(k, q)) ? 2 : s;
    }

    // "mullvad" alone finds the switch under System; a word after it picks a country.
    function mullvadResults(wanted) {
        const q = wanted.toLowerCase().trim();
        const here = Sys.state.vpn ? Sys.state.vpn.country : "";
        const places = Search.byUse(Sys.countries, Sys.countryMemory.picks, Date.now())
            .filter(c => !q || Search.wordsMatch([c.name, c.code, countryAliases[c.code.toUpperCase()] || ""].join(" "), q))
            .slice(0, 8)
            .map(c => ({ group: "Mullvad", title: c.name, note: c.code === here ? "Current" : "Set", kind: "action", value: () => { Sys.setMullvadCountry(c.code); Ui.close(); }, glyph: "globe" }));
        // Last, so typing a country's first letter can't land on the switch.
        const word = Sys.mullvadOn ? "Disconnect" : "Connect";
        const toggle = q && Search.wordsMatch(word + (Sys.mullvadOn ? " off" : " on"), q)
            ? [{ group: "Mullvad", title: word, note: "Mullvad", kind: "action", value: () => { Sys.toggleMullvad(); Ui.close(); }, glyph: "power" }]
            : [];
        return places.concat(toggle);
    }

    readonly property var results: {
        if (clipboardMode) {
            const wanted = query.toLowerCase();
            return clips.filter(c => c.text.toLowerCase().includes(wanted)).slice(0, 8)
                .map(c => ({ group: "Clipboard", title: c.text, note: "Copy", kind: "clip", value: c.line, glyph: "clipboard" }));
        }
        if (query === "") return [];
        // "tz" and "weather" lead here too: one place sets both.
        // The short words need a town after them, so "lock" and the like still search.
        const placeQuery = /^(?:location|time ?zone)(?:\s+(.*))?$|^(?:loc|tz|weather)\s+(.*)$/i.exec(query);
        if (placeQuery)
            return cityResults((placeQuery[1] || placeQuery[2] || "").trim());
        const relayQuery = /^mullvad\s+(.*)$/i.exec(query);
        if (relayQuery)
            return mullvadResults(relayQuery[1]);
        if (query.startsWith(">")) {
            const cmd = query.slice(1).trim();
            return [{ group: "Command", title: cmd || "Type a command", note: "Run", kind: "command", value: cmd }];
        }
        const q = query.toLowerCase();
        const answer = Search.calculate(query);
        const sums = answer === null ? [] : [{ group: "Calculator", title: answer, note: "Copy", kind: "copy", value: answer, glyph: "calculator" }];
        const converted = answer === null ? Search.convert(query, rates) : null;
        const conversions = converted ? [{ group: "Conversion", title: converted.title, note: converted.note, kind: "copy", value: converted.value, glyph: "calculator" }] : [];
        const found = apps.map(a => ({ a, s: appScore(a, q) })).filter(x => x.s >= 0)
            .sort((x, y) => x.s - y.s || used("app:" + y.a.id) - used("app:" + x.a.id))
            .slice(0, 4)
            .map(x => ({ group: "Applications", title: x.a.name, note: "Open", kind: "app", value: x.a, icon: x.a.icon, key: "app:" + x.a.id, match: x.s }));
        // An app's own actions, like a private window. The last word typed has to be
        // part of the action, so "firefox" alone lists the app and not all its actions.
        const last = q.split(/\s+/).pop();
        const appActions = [];
        if (q.length >= 2)
            for (const a of apps)
                for (const act of Array.from(a.actions || []))
                    if (Search.wordsMatch(a.name + " " + act.name, q) && Search.wordsMatch(act.name, last))
                        appActions.push({ group: "Actions", title: act.name, note: a.name, kind: "app", value: act, icon: act.icon || a.icon, key: "action:" + a.id + "/" + act.id, match: Search.score(act.name, q) });
        appActions.sort((x, y) => used(y.key) - used(x.key));
        appActions.splice(3);
        const windows = ToplevelManager.toplevels.values
            .filter(t => (t.title + " " + t.appId).toLowerCase().includes(q)).slice(0, 3)
            .map(t => ({ group: "Open windows", title: t.title || t.appId, note: "Switch", kind: "window", value: t }));
        const system = actions.filter(a => Search.score(a.title, q) >= 0).slice(0, 3)
            .map(a => ({ group: "System", title: a.title, note: a.note, kind: "action", value: a.run, glyph: "power", key: "system:" + a.title, match: Search.score(a.title, q) }));
        const inFiles = files.map(f => ({ group: "Files", title: f.name, note: f.folder, kind: "file", value: f.path, glyph: "folder", key: "file:" + f.path, match: Search.score(f.name, q) }));
        const web = answer === null && !converted ? [{ group: "Web", title: "Search the web for " + query, note: "Open", kind: "web", value: query, glyph: "globe" }] : [];
        const all = sums.concat(conversions, found, appActions, windows, system, inFiles, web);
        const hit = Search.topHit(all, memory, q, Date.now());
        if (hit >= 0) {
            const top = Object.assign({}, all[hit], { group: "Top Hit" });
            all.splice(hit, 1);
            all.unshift(top);
        }
        return all;
    }

    // What Ctrl+Enter does on top of the usual action.
    function altOf(item) {
        if (!item) return null;
        if (item.kind === "file")
            return { label: "Show in folder", run: () => Quickshell.execDetached(["xdg-open", item.value.slice(0, item.value.lastIndexOf("/")) || "/"]) };
        if (item.kind === "window")
            return { label: "Close window", run: () => item.value.close() };
        if (item.kind === "command" && item.value)
            return { label: "Run in terminal", run: () => Quickshell.execDetached(["kitty", "--hold", "sh", "-c", item.value]) };
        return null;
    }
    // What Ctrl+C copies, when nothing in the field is selected.
    function copyOf(item) {
        if (!item) return "";
        if (item.kind === "file" || item.kind === "copy" || item.kind === "web" || item.kind === "command") return item.value;
        if (item.kind === "window") return item.title;
        return "";
    }

    function learn(item) {
        if (!item || !item.key) return;
        memory = Search.remember(memory, query.toLowerCase(), item.key, Date.now());
        memoryFile.setText(JSON.stringify(memory));
    }

    onQueryChanged: {
        if (/^mullvad\s/i.test(query) && !Sys.countries.length)
            Sys.loadCountries();
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
    FileView {
        id: memoryFile
        path: root.stateDir + "/spotlight.json"
        printErrors: false
        onLoaded: {
            try {
                const m = JSON.parse(text());
                root.memory = { picks: m.picks || {}, typed: m.typed || {} };
            } catch (e) {
                console.warn("quiet-shell: bad spotlight memory", e);
            }
        }
    }
    // The script keeps its own copy for half a day, so asking each time is cheap.
    property real ratesAt: 0
    Process {
        id: ratesRead
        command: ["python3", Qt.resolvedUrl("scripts/rates.py").toString().replace("file://", "")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    if (text.trim()) {
                        root.rates = JSON.parse(text);
                        root.ratesAt = Date.now();
                    }
                } catch (e) {
                    console.warn("quiet-shell: bad rates", e);
                }
            }
        }
    }

    Binding { target: Ui; property: "spotlightQuery"; value: input.text }

    onResultsChanged: {
        selected = Math.min(selected, Math.max(results.length - 1, 0));
        if (visible) Ui.spotlightResults = results.map(r => r.group + ": " + r.title);
    }

    function launch(item) {
        if (!item) return;
        learn(item);
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
    function launchAlt(item) {
        const alt = altOf(item);
        if (!alt) return launch(item);
        learn(item);
        alt.run();
        Ui.close();
    }
    function copy(item) {
        const text = copyOf(item);
        if (!text) return false;
        learn(item);
        Quickshell.execDetached(["wl-copy", text]);
        Ui.close();
        return true;
    }

    onVisibleChanged: {
        if (!visible) return;
        input.text = "";
        selected = 0;
        input.forceActiveFocus();
        if (!ratesRead.running && Date.now() - ratesAt > 3600000)
            ratesRead.running = true;
    }

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
            Keys.onPressed: event => {
                const item = root.results[root.selected];
                const ctrl = event.modifiers & Qt.ControlModifier;
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (ctrl) root.launchAlt(item);
                    else root.launch(item);
                    event.accepted = true;
                } else if (ctrl && event.key === Qt.Key_C && input.selectedText === "") {
                    event.accepted = root.copy(item);
                }
            }
            Label {
                visible: input.text === ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.clipboardMode ? "Search clipboard history" : "Search apps, files and settings"
                font.pixelSize: 22
                color: Theme.dim
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
                readonly property bool current: index === root.selected
                readonly property var alt: current ? root.altOf(modelData) : null
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
                    id: rowPress
                    Layout.fillWidth: true
                    implicitHeight: 46
                    radius: 14
                    name: rowItem.modelData.title
                    rest: rowItem.current ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.26) : "transparent"
                    hover: rest
                    onClicked: root.launch(rowItem.modelData)
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 14
                        spacing: 12
                        AppIcon { size: 30; lit: rowItem.current || rowPress.hovered; icon: rowItem.modelData.icon || ""; fallback: rowItem.modelData.title; glyph: rowItem.modelData.kind === "command" ? "terminal" : rowItem.modelData.glyph || "" }
                        Label { Layout.fillWidth: true; text: rowItem.modelData.title; font.pixelSize: 14 }
                        Label { Layout.maximumWidth: 220; text: rowItem.modelData.note; font.pixelSize: 12; color: Theme.dim; elide: Text.ElideLeft }
                        // The second action, shown only where it would apply.
                        Label {
                            visible: rowItem.alt !== null
                            text: rowItem.alt ? "Ctrl ↵ " + rowItem.alt.label : ""
                            font.pixelSize: 11
                            color: Theme.faint
                        }
                    }
                }
            }
        }
    }
}
