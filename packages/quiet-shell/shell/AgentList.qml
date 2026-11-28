import QtQuick
import QtQuick.Layouts

// The sessions in one of AgentStatus's styles: rows (compact, detailed, pets) or
// the feed. Background jobs that finished are counted at the end, unless shown.
ColumnLayout {
    id: root
    property string style: "compact"
    property int feedRows: 10
    spacing: style === "compact" ? 2 : 8

    Repeater {
        model: root.style === "feed" ? [] : AgentStatus.sessions
        AgentItem {
            required property var modelData
            Layout.fillWidth: true
            session: modelData
            style: root.style
        }
    }
    AgentFeed {
        visible: root.style === "feed"
        Layout.fillWidth: true
        rows: root.feedRows
    }
    Label {
        visible: AgentStatus.all.length === 0
        text: "No agents running"
        font.pixelSize: 11
        color: Theme.faint
    }
    Label {
        visible: !AgentStatus.shown("finished") && AgentStatus.finishedCount > 0
        text: AgentStatus.finishedCount + (AgentStatus.finishedCount === 1 ? " background job finished" : " background jobs finished")
        font.pixelSize: 10
        color: Theme.faint
    }
}
