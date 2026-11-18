import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// Every running agent session side by side (SUPER+A), sorted so the ones waiting
// on you come first: what you last asked, what it has done since, the bottom of
// its terminal (where a permission prompt or question shows), and the limits with
// when they run out at this pace. The reply line at the bottom types into the
// selected session; number keys answer its prompt, x interrupts it, Return goes to
// its terminal. scripts/agents.py --detail gathers everything, every few seconds
// while the board is open.
Item {
    id: root

    property var info: null
    property real now: Date.now() / 1000
    // Selection follows a session, not a position, as the order changes under it.
    property string selectedId: ""

    // Waiting on you first, then a finished turn, then work in progress; by name
    // within each, so columns don't swap places as they report.
    readonly property var order: ({ waiting: 0, done: 1, working: 2, idle: 3 })
    readonly property var sessions: info ? info.sessions.slice().sort((a, b) =>
        (order[a.state] ?? 4) - (order[b.state] ?? 4) || (a.name || a.project).localeCompare(b.name || b.project)) : []
    readonly property int selected: Math.max(0, sessions.findIndex(s => s.id === selectedId))
    readonly property var current: sessions.length ? sessions[selected] : null
    readonly property var tools: info ? [["Claude", "claude"], ["Codex", "codex"]].filter(t => has(info[t[1]])) : []
    readonly property int waitingCount: sessions.filter(s => s.state === "waiting").length

    function has(tool) { return !!tool && tool.paid !== false && (tool.five_hour !== null || tool.week !== null); }
    function span(seconds) {
        const minutes = Math.max(0, Math.round(seconds / 60));
        if (minutes < 60)
            return minutes + "m";
        if (minutes < 24 * 60)
            return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m";
        return Math.floor(minutes / 1440) + "d " + Math.floor(minutes % 1440 / 60) + "h";
    }
    function select(step) {
        if (!sessions.length)
            return;
        const at = (selected + step + sessions.length) % sessions.length;
        selectedId = sessions[at].id;
        columns.positionViewAtIndex(at, ListView.Contain);
    }
    function stateText(s) {
        return ({ waiting: "Needs you", done: "Your turn", working: "Working", idle: "Idle" })[s.state] || s.state;
    }

    // Keys while no field is being typed in; ShellWindow hands them over.
    function pressKey(event) {
        const letter = event.text.toLowerCase();
        if (letter === "h" || event.key === Qt.Key_Left) { select(-1); return true; }
        if (letter === "l" || event.key === Qt.Key_Right) { select(1); return true; }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { Agents.jump(current); return true; }
        if (letter === "r" || letter === "i" || letter === "/") { replyInput.forceActiveFocus(); return true; }
        if (letter === "x") { Agents.press(current, "escape"); soon.restart(); return true; }
        if (["1", "2", "3"].includes(event.text)) { Agents.press(current, event.text); soon.restart(); return true; }
        return false;
    }

    Process {
        id: probe
        command: ["python3", Qt.resolvedUrl("scripts/agents.py").toString().replace("file://", ""), "--detail"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.info = JSON.parse(text);
                    if (!root.sessions.some(s => s.id === root.selectedId) && root.sessions.length)
                        root.selectedId = root.sessions[0].id;
                } catch (e) {
                    console.warn("quiet-shell: bad agents output", e);
                }
            }
        }
    }
    function refresh() {
        now = Date.now() / 1000;
        if (!probe.running)
            probe.running = true;
    }
    Timer {
        interval: 2500
        // The board only exists while it is open.
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
    // After a key or a reply, show what it did without waiting the full interval.
    Timer { id: soon; interval: 700; onTriggered: root.refresh() }

    Rectangle { anchors.fill: parent; color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.95) }
    MouseArea { anchors.fill: parent }

    // Title, what needs you, and the limits.
    RowLayout {
        id: header
        x: 48
        y: 28
        width: parent.width - 96
        spacing: 32
        Column {
            Layout.alignment: Qt.AlignTop
            spacing: 2
            Label { text: "Agents"; font.pixelSize: 28; font.weight: Font.Medium }
            Label {
                text: !root.info ? "" : root.sessions.length === 0 ? "Nothing running"
                    : [root.waitingCount ? root.waitingCount + " waiting on you" : "",
                       root.sessions.filter(s => s.state === "working").length + " working",
                       root.sessions.length + " running"].filter(s => s).join(" · ")
                color: root.waitingCount ? Theme.text : Theme.dim
                font.pixelSize: 13
            }
        }
        Item { Layout.fillWidth: true }
        Repeater {
            model: root.tools
            ColumnLayout {
                id: tool
                required property var modelData
                readonly property var limits: root.info[modelData[1]]
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: 300
                spacing: 6
                Label { text: tool.modelData[0]; font.pixelSize: 12; font.weight: Font.Medium }
                Repeater {
                    model: [["5h", tool.limits.five_hour], ["week", tool.limits.week]].filter(w => w[1] !== null)
                    ColumnLayout {
                        id: limit
                        required property var modelData
                        readonly property var w: modelData[1]
                        readonly property bool short: !!w.runs_out
                        Layout.fillWidth: true
                        spacing: 2
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Label { Layout.preferredWidth: 30; text: limit.modelData[0]; font.pixelSize: 10; color: Theme.faint }
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 4
                                Rectangle { anchors.fill: parent; radius: 2; color: Theme.track }
                                Rectangle {
                                    width: parent.width * Math.min(100, limit.w.used) / 100
                                    height: parent.height
                                    radius: 2
                                    color: limit.w.used >= 90 || limit.short ? Theme.text : Theme.accent
                                    Behavior on width { NumberAnimation { duration: Theme.motion } }
                                }
                            }
                            Label {
                                Layout.preferredWidth: 104
                                horizontalAlignment: Text.AlignRight
                                text: limit.w.used + "%" + (limit.w.resets ? " · resets " + root.span(limit.w.resets - root.now) : "")
                                font.pixelSize: 10
                                font.features: { "tnum": 1 }
                                color: Theme.dim
                            }
                        }
                        // Only said when the pace runs it out before it resets.
                        Label {
                            visible: limit.short
                            Layout.leftMargin: 38
                            text: limit.short ? "At this pace, runs out in " + root.span(limit.w.runs_out - root.now)
                                + ", " + root.span(limit.w.resets - limit.w.runs_out) + " before it resets" : ""
                            font.pixelSize: 10
                            color: Theme.text
                        }
                    }
                }
            }
        }
    }

    Label {
        anchors.centerIn: parent
        visible: !!root.info && root.sessions.length === 0
        text: "No agents running"
        color: Theme.dim
        font.pixelSize: 16
    }

    // One column per session.
    ListView {
        id: columns
        x: 48
        y: header.y + header.height + 24
        width: parent.width - 96
        height: replyBar.y - y - 18
        orientation: ListView.Horizontal
        spacing: 16
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Repeated output keeps the same delegates, so nothing flickers as it refreshes.
        model: root.sessions.length
        readonly property real columnWidth: Math.max(380, Math.min(560, (width - spacing * (Math.max(1, count) - 1)) / Math.max(1, count)))
        delegate: Item {
            id: column
            required property int index
            readonly property var s: root.sessions[index] ?? null
            readonly property bool chosen: index === root.selected
            width: columns.columnWidth
            height: columns.height
            visible: s !== null

            Glass { anchors.fill: parent; radius: 22; tint: column.chosen ? Theme.fillHover : Theme.glass }
            Rectangle {
                anchors.fill: parent
                radius: 22
                color: "transparent"
                border.width: column.chosen ? 2 : 0
                border.color: Theme.accent
            }
            MouseArea {
                anchors.fill: parent
                onClicked: root.selectedId = column.s.id
                onDoubleClicked: Agents.jump(column.s)
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 18
                spacing: 10

                // What it is.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        readonly property bool breathing: column.s && (column.s.state === "working" || column.s.state === "waiting")
                        implicitWidth: 8
                        implicitHeight: 8
                        radius: 4
                        color: column.s && column.s.state === "waiting" ? Theme.text : column.s && column.s.state === "working" ? Theme.accent : Theme.faint
                        SequentialAnimation on opacity {
                            running: parent.breathing && !Theme.reducedMotion
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.3; duration: 800; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine }
                            onStopped: parent.opacity = 1
                        }
                    }
                    Label {
                        text: column.s ? root.stateText(column.s) : ""
                        font.pixelSize: 11
                        font.weight: Font.Medium
                        color: column.s && column.s.state === "waiting" ? Theme.text : Theme.dim
                    }
                    Item { Layout.fillWidth: true }
                    Press {
                        visible: column.s && !!column.s.terminal
                        implicitWidth: 26
                        implicitHeight: 26
                        radius: 13
                        name: "Go to " + (column.s ? column.s.name : "")
                        onClicked: Agents.jump(column.s)
                        Icon { anchors.centerIn: parent; name: "terminal"; size: 14; color: Theme.dim }
                    }
                }
                Label {
                    Layout.fillWidth: true
                    text: column.s ? column.s.name || column.s.project || "~" : ""
                    elide: Text.ElideRight
                    font.pixelSize: 17
                    font.weight: Font.Medium
                }
                Label {
                    Layout.fillWidth: true
                    Layout.topMargin: -6
                    text: !column.s ? "" : [
                        column.s.project,
                        column.s.branch && column.s.branch !== "HEAD" ? column.s.branch : "",
                        column.s.model,
                        column.s.context !== null && column.s.context !== undefined ? "ctx " + Math.round(column.s.context) + "%" : "",
                        column.s.cost !== null && column.s.cost !== undefined ? "$" + column.s.cost.toFixed(2) : "",
                        column.s.started ? root.span(root.now - column.s.started) : ""
                    ].filter(x => x).join(" · ")
                    elide: Text.ElideRight
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                    color: Theme.dim
                }
                // Why it waits, in Claude's words.
                Label {
                    visible: column.s && column.s.waiting !== "" && column.s.state === "waiting"
                    Layout.fillWidth: true
                    text: column.s ? column.s.waiting : ""
                    wrapMode: Text.Wrap
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.hairline }

                Label { visible: !!column.s && column.s.prompt !== ""; text: "You asked"; font.pixelSize: 10; color: Theme.faint }
                Label {
                    visible: !!column.s && column.s.prompt !== ""
                    Layout.fillWidth: true
                    text: column.s ? column.s.prompt : ""
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    font.pixelSize: 12
                }
                Label { visible: !!column.s && column.s.tools && column.s.tools.length > 0; text: "Since then"; font.pixelSize: 10; color: Theme.faint }
                Repeater {
                    model: column.s && column.s.tools ? column.s.tools : []
                    RowLayout {
                        id: call
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        Label { text: call.modelData.name; font.pixelSize: 11; font.weight: Font.Medium; color: Theme.dim }
                        Label {
                            Layout.fillWidth: true
                            text: call.modelData.brief
                            elide: Text.ElideRight
                            font.pixelSize: 11
                            color: Theme.faint
                        }
                    }
                }
                Label {
                    visible: !!column.s && !!column.s.said
                    Layout.fillWidth: true
                    text: column.s ? column.s.said || "" : ""
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    font.pixelSize: 12
                    color: Theme.dim
                }

                // The bottom of its terminal, as it is now.
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 90
                    Rectangle { anchors.fill: parent; radius: 12; color: Qt.rgba(0, 0, 0, 0.28) }
                    Text {
                        anchors.fill: parent
                        anchors.margins: 10
                        verticalAlignment: Text.AlignBottom
                        clip: true
                        text: !column.s ? "" : column.s.screen
                            || (column.s.terminal ? "" : "Its terminal was opened before kitty listened on a socket; reopen it to see and drive it here.")
                        textFormat: Text.PlainText
                        // The screen keeps its own lines; the note about an old terminal wraps.
                        wrapMode: column.s && column.s.screen ? Text.NoWrap : Text.Wrap
                        elide: Text.ElideNone
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 10
                        color: column.s && column.s.screen ? Theme.text : Theme.faint
                        opacity: 0.9
                    }
                }
            }
        }
    }

    // Typed into the selected session; Return sends and presses Enter there.
    Item {
        id: replyBar
        x: 48
        width: parent.width - 96
        height: 46
        y: parent.height - height - 40
        visible: root.sessions.length > 0
        Rectangle {
            anchors.fill: parent
            radius: 14
            color: Theme.fill
            border.width: replyInput.activeFocus ? 1 : 0
            border.color: Theme.accent
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 12
            Label {
                text: root.current ? "To " + (root.current.name || root.current.project) : ""
                font.pixelSize: 12
                font.weight: Font.Medium
                color: Theme.dim
            }
            TextInput {
                id: replyInput
                Layout.fillWidth: true
                enabled: !!root.current && !!root.current.terminal
                color: Theme.text
                selectionColor: Theme.accent
                font.family: Theme.font
                font.pixelSize: 14
                clip: true
                Accessible.role: Accessible.EditableText
                Accessible.name: "Reply to the selected agent"
                Keys.onReturnPressed: {
                    if (text.trim() === "")
                        return;
                    Agents.reply(root.current, text);
                    text = "";
                    soon.restart();
                }
                // Escape leaves the line for the board's keys, then closes as usual.
                Keys.onEscapePressed: event => {
                    if (text !== "")
                        text = "";
                    else
                        Ui.refocus();
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: replyInput.text === ""
                    text: !root.current ? "" : root.current.terminal ? (replyInput.activeFocus ? "Type, then Return to send" : "r to reply")
                        : "This session's terminal can't be reached; reopen it in a new kitty"
                    color: Theme.faint
                    font.pixelSize: 13
                }
            }
        }
    }
    Label {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: replyBar.bottom
        anchors.topMargin: 12
        visible: root.sessions.length > 0
        text: "h l choose · Return go to · r reply · 1 2 3 answer · x interrupt · Esc close"
        font.pixelSize: 11
        color: Theme.faint
    }
}
