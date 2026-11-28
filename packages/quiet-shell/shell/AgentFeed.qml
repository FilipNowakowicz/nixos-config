import QtQuick
import QtQuick.Layouts

// Every agent's last steps in one list, newest first, like a log you can glance
// at: when, who, and what it did. Sessions waiting on you stay pinned on top.
ColumnLayout {
    id: root
    property int rows: 10
    spacing: 3

    readonly property var steps: {
        const out = [];
        for (const s of AgentStatus.sessions) {
            for (const r of s.recent || [])
                if (r.at)
                    out.push({ at: r.at, kind: r.kind, text: r.text || r.tool, session: s });
            for (const a of AgentStatus.shown("subagents") ? s.subagents || [] : [])
                if (a.doing && a.doing.at)
                    out.push({ at: a.doing.at, kind: a.doing.kind, text: "↳ " + (a.doing.text || a.doing.tool), session: s });
        }
        out.sort((a, b) => b.at - a.at);
        return out.slice(0, rows);
    }

    Repeater {
        model: AgentStatus.waitingSessions
        Press {
            id: wait
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: 22
            radius: 8
            enabled: !!modelData.terminal
            name: "Go to " + AgentStatus.title(modelData)
            onClicked: AgentStatus.jump(modelData)
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 4
                spacing: 6
                Icon { name: "bell-ring"; size: 12 }
                Label {
                    Layout.fillWidth: true
                    text: AgentStatus.title(wait.modelData) + " needs you" + (wait.modelData.waiting ? " · " + AgentStatus.waitText(wait.modelData) : "")
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }
            }
        }
    }
    Repeater {
        model: root.steps
        Press {
            id: step
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: 20
            radius: 6
            enabled: !!modelData.session.terminal
            name: AgentStatus.title(modelData.session) + ": " + modelData.text
            onClicked: AgentStatus.jump(modelData.session)
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 4
                spacing: 6
                Label {
                    Layout.preferredWidth: 34
                    text: AgentStatus.clock(step.modelData.at)
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                }
                Icon { name: AgentStatus.kindIcons[step.modelData.kind] || "hammer"; size: 11; color: Theme.dim }
                Label {
                    Layout.preferredWidth: 78
                    text: AgentStatus.title(step.modelData.session)
                    font.pixelSize: 10
                    color: Theme.dim
                }
                Label {
                    Layout.fillWidth: true
                    text: step.modelData.text
                    font.pixelSize: 10
                    color: Theme.text
                }
            }
        }
    }
    Label {
        visible: root.steps.length === 0 && AgentStatus.waitingSessions.length === 0
        text: "Nothing has happened lately"
        font.pixelSize: 11
        color: Theme.faint
    }
}
