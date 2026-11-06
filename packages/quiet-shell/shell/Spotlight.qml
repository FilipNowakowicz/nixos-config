import QtQuick
import QtQuick.Layouts
import Quickshell
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
    readonly property var results: {
        if (query === "") return [];
        if (query.startsWith(">")) {
            const cmd = query.slice(1).trim();
            return [{ group: "Command", title: cmd || "Type a command", note: "Run", kind: "command", value: cmd }];
        }
        const q = query.toLowerCase();
        const found = apps.map(a => ({ a, s: score(a.name, q) })).filter(x => x.s >= 0)
            .sort((x, y) => x.s - y.s).slice(0, 6)
            .map(x => ({ group: "Applications", title: x.a.name, note: "Open", kind: "app", value: x.a, icon: x.a.icon }));
        const windows = ToplevelManager.toplevels.values
            .filter(t => (t.title + " " + t.appId).toLowerCase().includes(q)).slice(0, 4)
            .map(t => ({ group: "Open windows", title: t.title || t.appId, note: "Switch", kind: "window", value: t }));
        return found.concat(windows);
    }
    onResultsChanged: selected = Math.min(selected, Math.max(results.length - 1, 0))

    function launch(item) {
        if (!item) return;
        if (item.kind === "app") item.value.execute();
        if (item.kind === "window") Dockable.revealWayland(item.value);
        if (item.kind === "command" && item.value) Quickshell.execDetached(["sh", "-c", item.value]);
        Ui.close();
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
        Icon { name: "search"; size: 21; color: Theme.dim }
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
                text: "Search apps and windows"
                font.pixelSize: 22
                color: Theme.dim
            }
        }
    }

    RowLayout {
        id: suggestions
        visible: root.query === ""
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
                        AppIcon { size: 30; icon: rowItem.modelData.icon || ""; fallback: rowItem.modelData.title; glyph: rowItem.modelData.kind === "command" ? "terminal" : "" }
                        Label { Layout.fillWidth: true; text: rowItem.modelData.title; font.pixelSize: 14 }
                        Label { text: rowItem.modelData.note; font.pixelSize: 12; color: Theme.dim }
                    }
                }
            }
        }
    }
}
