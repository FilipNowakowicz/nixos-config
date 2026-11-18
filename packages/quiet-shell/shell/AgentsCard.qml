import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// How much of each subscribed tool's usage limits is spent, when each comes back,
// and how many of its sessions are working. A tool whose subscription has ended is
// left out, even while its last limits are still on record. scripts/agents.py reads
// what the tools leave behind; it is asked only while the card is on screen.
// A tool's name unfolds its sessions, each of which can be jumped to or replied to.
Item {
    id: root
    implicitHeight: body.implicitHeight + 24
    readonly property var tools: info ? [["Claude", "claude"], ["Codex", "codex"]].filter(t => has(info[t[1]])) : []
    readonly property bool hasContent: tools.length > 0
    visible: hasContent

    property var info: null
    property real now: Date.now() / 1000
    // The tool whose sessions are unfolded, if any.
    property string open: ""
    // Reply lines open right now.
    property int typing: 0

    function reply(session, text) {
        Agents.reply(session, text);
        soon.restart();
    }
    // A reply usually sets a session working; show that without waiting the full interval.
    Timer { id: soon; interval: 1500; onTriggered: if (!probe.running && root.typing === 0) probe.running = true }

    function has(tool) { return !!tool && tool.paid !== false && (tool.five_hour !== null || tool.week !== null); }
    function sessionsOf(tool) {
        const all = info ? info.sessions.filter(s => s.tool === tool) : [];
        const working = all.filter(s => s.state === "working").length;
        const idle = all.length - working;
        return [working ? working + " working" : "", idle ? idle + " idle" : ""].filter(s => s).join(" · ");
    }
    function until(at) {
        if (!at)
            return "";
        const minutes = Math.max(0, Math.round((at - now) / 60));
        if (minutes < 60)
            return minutes + "m";
        if (minutes < 24 * 60)
            return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m";
        return Math.floor(minutes / 1440) + "d " + Math.floor(minutes % 1440 / 60) + "h";
    }

    Process {
        id: probe
        command: ["python3", Qt.resolvedUrl("scripts/agents.py").toString().replace("file://", "")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.info = JSON.parse(text);
                } catch (e) {
                    console.warn("quiet-shell: bad agents output", e);
                }
            }
        }
    }
    Timer {
        interval: 20000
        // The overview, and so this card, only exists while it is open.
        running: true
        repeat: true
        triggeredOnStart: true
        // New output rebuilds the session rows, which would wipe a reply being typed.
        onTriggered: { root.now = Date.now() / 1000; if (!probe.running && root.typing === 0) probe.running = true; }
    }

    Glass { anchors.fill: parent; radius: 22 }
    ColumnLayout {
        id: body
        x: 16
        y: 12
        width: parent.width - 32
        spacing: 8

        Repeater {
            model: root.tools
            ColumnLayout {
                id: tool
                required property var modelData
                required property int index
                readonly property var limits: root.info[modelData[1]]
                Layout.fillWidth: true
                spacing: 5
                readonly property var sessions: root.info.sessions.filter(s => s.tool === modelData[1])
                readonly property bool unfolded: root.open === modelData[1] && sessions.length > 0
                RowLayout {
                    Layout.fillWidth: true
                    Press {
                        Layout.fillWidth: true
                        implicitHeight: 22
                        radius: 8
                        enabled: tool.sessions.length > 0
                        name: (tool.unfolded ? "Fold " : "Unfold ") + tool.modelData[0] + " sessions"
                        onClicked: root.open = tool.unfolded ? "" : tool.modelData[1]
                        RowLayout {
                            anchors.fill: parent
                            spacing: 4
                            Label { text: tool.modelData[0]; font.pixelSize: 12; font.weight: Font.Medium }
                            Icon {
                                visible: tool.sessions.length > 0
                                name: "chevron-down"
                                size: 12
                                color: Theme.faint
                                rotation: tool.unfolded ? 180 : 0
                                Behavior on rotation { NumberAnimation { duration: Theme.motion } }
                            }
                            Item { Layout.fillWidth: true }
                        }
                    }
                    // Something working breathes, as the session rows did.
                    Rectangle {
                        readonly property bool working: root.sessionsOf(tool.modelData[1]).includes("working")
                        visible: count.text !== ""
                        implicitWidth: 6
                        implicitHeight: 6
                        radius: 3
                        color: working ? Theme.accent : Theme.faint
                        SequentialAnimation on opacity {
                            running: parent.working && !Theme.reducedMotion
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                            onStopped: parent.opacity = 1
                        }
                    }
                    Label { id: count; text: root.sessionsOf(tool.modelData[1]); font.pixelSize: 10; color: Theme.dim }
                    // Everything about every session, side by side (SUPER+A).
                    Press {
                        visible: tool.index === 0
                        implicitWidth: 22
                        implicitHeight: 22
                        radius: 11
                        name: "Open the agent board"
                        onClicked: Ui.toggleBoard()
                        Icon { anchors.centerIn: parent; name: "layout-grid"; size: 12; color: Theme.dim }
                    }
                }
                Repeater {
                    model: [["5h", tool.limits.five_hour], ["week", tool.limits.week]].filter(w => w[1] !== null)
                    RowLayout {
                        id: limit
                        required property var modelData
                        readonly property var w: modelData[1]
                        Layout.fillWidth: true
                        spacing: 8
                        Label { Layout.preferredWidth: 30; text: limit.modelData[0]; font.pixelSize: 10; color: Theme.faint }
                        // Spent, on the same thin track the sliders use; it brightens near the end.
                        Item {
                            Layout.fillWidth: true
                            implicitHeight: 4
                            Rectangle { anchors.fill: parent; radius: 2; color: Theme.track }
                            Rectangle {
                                width: parent.width * Math.min(100, limit.w.used) / 100
                                height: parent.height
                                radius: 2
                                color: limit.w.used >= 90 ? Theme.text : Theme.accent
                                opacity: limit.w.used >= 90 ? 1 : 0.85
                                Behavior on width { NumberAnimation { duration: Theme.motion } }
                            }
                        }
                        Label {
                            Layout.preferredWidth: 88
                            horizontalAlignment: Text.AlignRight
                            text: limit.w.used + "%" + (limit.w.resets ? " · " + root.until(limit.w.resets) : "")
                            font.pixelSize: 10
                            font.features: { "tnum": 1 }
                            color: limit.w.used >= 90 ? Theme.text : Theme.dim
                        }
                    }
                }
                Repeater {
                    model: tool.unfolded ? tool.sessions : []
                    AgentSession {
                        required property var modelData
                        Layout.fillWidth: true
                        session: modelData
                        onJump: Agents.jump(modelData)
                        onReply: text => root.reply(modelData, text)
                        onReplyingChanged: root.typing += replying ? 1 : -1
                        Component.onDestruction: if (replying) root.typing -= 1
                    }
                }
            }
        }
    }
}
