import QtQuick
import QtQuick.Layouts

// One running agent session, in one of AgentStatus's styles:
//   compact   a line: its state, its title, how it stands
//   detailed  that, plus model and branch, context and cost, what it is doing,
//             your last prompt, its last reply, and its subagents beneath
//   pets      a little creature whose face and words say what it is up to
// Which of the detailed lines show is AgentStatus's `show`. A click jumps to its
// terminal, found through kitty's remote-control socket. A Claude session also has
// a switch to carry on by itself after a usage limit: scripts/resume.py types into
// it once the limit resets.
ColumnLayout {
    id: root
    required property var session
    property string style: "compact"
    readonly property var s: session
    readonly property bool reachable: !!s.terminal
    readonly property bool working: s.state === "working"
    readonly property bool waiting: s.state === "waiting"
    readonly property bool limited: s.limited !== null && s.limited !== undefined
    readonly property bool pets: style === "pets"
    readonly property bool detailed: style === "detailed"
    readonly property var subs: AgentStatus.shown("subagents") ? (s.subagents || []) : []
    // A click shows at once; the next poll rebuilds the row from the switch's file.
    property var pending: null
    readonly property bool resumes: pending !== null ? pending : !!s.resume
    function line(...parts) { return parts.filter(p => p).join(" · "); }

    spacing: 2
    opacity: s.state === "done" ? 0.6 : 1

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        // The state: a dot that breathes while working and rings while it waits.
        Item {
            visible: !root.pets
            implicitWidth: 10
            implicitHeight: 10
            Layout.alignment: root.detailed ? Qt.AlignTop : Qt.AlignVCenter
            Layout.topMargin: root.detailed ? 7 : 0
            Rectangle {
                anchors.centerIn: parent
                width: root.waiting ? 8 : 6
                height: width
                radius: width / 2
                color: root.waiting ? Theme.text : root.working ? Theme.accent : Theme.faint
                SequentialAnimation on opacity {
                    running: (root.working || root.waiting) && !Theme.reducedMotion
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: root.waiting ? 450 : 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: root.waiting ? 450 : 900; easing.type: Easing.InOutSine }
                    onStopped: parent.opacity = 1
                }
            }
            Rectangle {
                visible: root.waiting
                anchors.centerIn: parent
                width: 12
                height: 12
                radius: 6
                color: "transparent"
                border.width: 1
                border.color: Theme.dim
            }
        }
        Label {
            visible: root.pets
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 3
            Layout.preferredWidth: 58
            text: AgentStatus.face(root.s)
            font.family: "monospace"
            font.pixelSize: 13
            elide: Text.ElideNone
            color: root.waiting ? Theme.text : root.working ? Theme.text : Theme.dim
        }

        Press {
            Layout.fillWidth: true
            implicitHeight: body.implicitHeight + 6
            radius: 8
            enabled: root.reachable
            name: "Go to " + AgentStatus.title(root.s)
            onClicked: AgentStatus.jump(root.s)
            ColumnLayout {
                id: body
                x: 4
                y: 3
                width: parent.width - 8
                spacing: 1
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Label {
                        Layout.fillWidth: true
                        text: AgentStatus.title(root.s) + (root.s.tool === "codex" ? "  ·  Codex" : "")
                        font.pixelSize: 12
                        font.weight: root.detailed || root.pets ? Font.Medium : Font.Normal
                    }
                    // Compact rows count the subagents still at work.
                    Label {
                        readonly property int running: root.subs.filter(a => a.state !== "done").length
                        visible: !root.detailed && !root.pets && running > 0
                        text: "+" + running
                        font.pixelSize: 10
                        color: Theme.dim
                    }
                    Label {
                        visible: !root.pets
                        text: AgentStatus.stateText(root.s)
                        font.pixelSize: 10
                        font.features: { "tnum": 1 }
                        font.weight: root.waiting ? Font.DemiBold : Font.Normal
                        color: root.waiting ? Theme.text : Theme.faint
                    }
                }
                // Pets: what the creature is doing, in its own words.
                Label {
                    visible: root.pets
                    Layout.fillWidth: true
                    text: AgentStatus.narrate(root.s)
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    color: root.waiting ? Theme.text : Theme.dim
                }
                Label {
                    visible: root.pets && text !== ""
                    Layout.fillWidth: true
                    text: root.line(
                        AgentStatus.shown("context") && root.s.context !== null && root.s.context !== undefined
                            ? AgentStatus.meter(root.s.context) + " " + Math.round(root.s.context) + "%" : "",
                        AgentStatus.shown("cost") ? AgentStatus.money(root.s.cost) : "",
                        root.working && root.s.asked ? "for " + AgentStatus.ago(root.s.asked) : "")
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                }
                // Detailed: model and branch, context and cost.
                Label {
                    visible: root.detailed && text !== ""
                    Layout.fillWidth: true
                    text: root.line(
                        AgentStatus.shown("meta") ? root.line(root.s.project !== AgentStatus.title(root.s) ? root.s.project : "",
                                                              root.s.branch && root.s.branch !== "main" ? root.s.branch : "",
                                                              root.s.model) : "",
                        root.s.background ? "background" : "",
                        AgentStatus.shown("context") ? AgentStatus.contextText(root.s) : "",
                        AgentStatus.shown("cost") ? AgentStatus.money(root.s.cost) : "")
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                }
                RowLayout {
                    visible: root.detailed && AgentStatus.shown("activity") && activity.text !== ""
                    Layout.fillWidth: true
                    spacing: 5
                    Icon { name: AgentStatus.kindIcon(root.s); size: 11; color: root.waiting ? Theme.text : Theme.dim }
                    Label {
                        id: activity
                        Layout.fillWidth: true
                        text: AgentStatus.doingText(root.s)
                        font.pixelSize: 11
                        color: root.waiting ? Theme.text : Theme.dim
                    }
                }
                Label {
                    visible: root.detailed && AgentStatus.shown("prompt") && !!root.s.prompt
                    Layout.fillWidth: true
                    text: "› " + (root.s.prompt || "")
                    font.pixelSize: 10
                    color: Theme.faint
                }
                Label {
                    visible: root.detailed && AgentStatus.shown("said") && !!root.s.said
                    Layout.fillWidth: true
                    text: "“" + (root.s.said || "") + "”"
                    font.pixelSize: 10
                    font.italic: true
                    color: Theme.faint
                }
                Label {
                    visible: root.detailed && !!root.s.job && root.s.job.tasks.length > 0
                    Layout.fillWidth: true
                    text: root.s.job ? root.s.job.tasks.length + (root.s.job.tasks.length === 1 ? " task: " : " tasks: ")
                        + root.s.job.tasks.map(t => t.label).join(", ") : ""
                    font.pixelSize: 10
                    color: Theme.faint
                }
            }
        }
        Press {
            visible: root.reachable && root.s.tool === "claude" && !!root.s.key && (root.limited || root.resumes)
            Layout.alignment: Qt.AlignTop
            implicitWidth: 24
            implicitHeight: 24
            radius: 12
            checkable: true
            toggled: root.resumes
            // Lit while on, as a chosen option is elsewhere in the shell.
            rest: root.resumes ? Theme.on : "transparent"
            hover: root.resumes ? Theme.on : Theme.fillHover
            name: (root.resumes ? "Stop resuming " : "Resume after the usage limit: ") + AgentStatus.title(root.s)
            onClicked: {
                const on = !root.resumes;
                root.pending = on;
                AgentStatus.setResume(root.s, on);
            }
            Icon { anchors.centerIn: parent; name: "timer"; size: 13; color: root.resumes ? Theme.onText : Theme.dim }
        }
    }

    // Subagents, beneath the session that started them. Compact rows only count them.
    Repeater {
        model: root.detailed || root.pets ? root.subs : []
        RowLayout {
            id: sub
            required property var modelData
            readonly property var a: modelData
            Layout.fillWidth: true
            Layout.leftMargin: root.pets ? 30 : 18
            spacing: 6
            opacity: a.state === "done" ? 0.55 : 1
            Label {
                text: root.pets ? AgentStatus.face(sub.a) : "↳"
                font.family: root.pets ? "monospace" : Theme.font
                font.pixelSize: root.pets ? 10 : 11
                elide: Text.ElideNone
                color: Theme.faint
            }
            Label {
                Layout.fillWidth: true
                text: root.line(sub.a.title,
                                sub.a.state === "done" ? "done" : AgentStatus.doingText(sub.a) || sub.a.type)
                font.pixelSize: 10
                color: Theme.dim
            }
            Label {
                text: root.line(sub.a.background ? "bg" : "", sub.a.state === "done" ? "" : sub.a.state)
                font.pixelSize: 10
                color: Theme.faint
            }
        }
    }
}
