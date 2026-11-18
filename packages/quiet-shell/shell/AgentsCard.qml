import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// How much of each subscribed tool's usage limits is spent, when each comes back,
// and how many of its sessions are working. A tool whose subscription has ended is
// left out, even while its last limits are still on record. scripts/agents.py reads
// what the tools leave behind; it is asked only while the card is on screen.
Item {
    id: root
    implicitHeight: body.implicitHeight + 24
    readonly property var tools: info ? [["Claude", "claude"], ["Codex", "codex"]].filter(t => has(info[t[1]])) : []
    readonly property bool hasContent: tools.length > 0
    visible: hasContent

    property var info: null
    property real now: Date.now() / 1000

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
        onTriggered: { root.now = Date.now() / 1000; if (!probe.running) probe.running = true; }
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
                readonly property var limits: root.info[modelData[1]]
                Layout.fillWidth: true
                spacing: 5
                RowLayout {
                    Layout.fillWidth: true
                    Label { Layout.fillWidth: true; text: tool.modelData[0]; font.pixelSize: 12; font.weight: Font.Medium }
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
            }
        }
    }
}
