import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// How much of Claude's and Codex's usage limits is spent, when each comes back, and
// which sessions are running. scripts/agents.py reads what the tools leave behind;
// it is asked only while the card is on screen.
Item {
    id: root
    implicitHeight: body.implicitHeight + 24
    readonly property bool hasContent: info !== null && (has(info.claude) || has(info.codex) || info.sessions.length > 0)
    visible: hasContent

    property var info: null
    property real now: Date.now() / 1000

    function has(tool) { return !!tool && (tool.five_hour !== null || tool.week !== null); }
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
    function ago(at) {
        const minutes = Math.round((now - at) / 60);
        return minutes < 1 ? "now" : minutes < 60 ? minutes + "m ago" : Math.floor(minutes / 60) + "h ago";
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
        onTriggered: { root.now = Date.now() / 1000; if (!probe.running) probe.running = true; }
    }

    Glass { anchors.fill: parent; radius: 22 }
    ColumnLayout {
        id: body
        x: 16
        y: 12
        width: parent.width - 32
        spacing: 8

        Label { text: "Agents"; font.pixelSize: 12; font.weight: Font.Medium }

        Repeater {
            model: root.info ? [["Claude", root.info.claude], ["Codex", root.info.codex]].filter(t => root.has(t[1])) : []
            ColumnLayout {
                id: tool
                required property var modelData
                Layout.fillWidth: true
                spacing: 4
                Label { text: tool.modelData[0]; font.pixelSize: 11; color: Theme.dim }
                Repeater {
                    model: [["5h", tool.modelData[1].five_hour], ["week", tool.modelData[1].week]].filter(w => w[1] !== null)
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
            }
        }

        Rectangle {
            visible: sessions.count > 0 && (root.has(root.info.claude) || root.has(root.info.codex))
            Layout.fillWidth: true
            implicitHeight: 1
            color: Theme.hairline
        }
        Repeater {
            id: sessions
            model: root.info ? root.info.sessions.slice(0, 4) : []
            RowLayout {
                id: session
                required property var modelData
                readonly property bool working: modelData.state === "working"
                Layout.fillWidth: true
                spacing: 8
                // A working session breathes; an idle one holds still.
                Rectangle {
                    implicitWidth: 6
                    implicitHeight: 6
                    radius: 3
                    color: session.working ? Theme.accent : Theme.faint
                    SequentialAnimation on opacity {
                        running: session.working && !Theme.reducedMotion
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                        onStopped: parent.opacity = 1
                    }
                }
                Label {
                    Layout.fillWidth: true
                    text: session.modelData.project || "~"
                    elide: Text.ElideRight
                    font.pixelSize: 12
                }
                Label {
                    text: [session.modelData.tool === "claude" ? session.modelData.model || "Claude" : "Codex",
                           session.modelData.context !== null ? "ctx " + Math.round(session.modelData.context) + "%" : "",
                           session.working ? "" : root.ago(session.modelData.at)].filter(s => s).join(" · ")
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                }
            }
        }
    }
}
