import QtQuick
import QtQuick.Layouts

// A small pill at the top right, while the bar is hidden, when an agent needs you
// (a permission prompt or a question) or, if chosen, has just finished its turn.
// A click opens the agents panel; a right click puts it away until that session
// changes again. Which of these it does is AgentStatus's `peek`.
Item {
    id: root
    // Session -> the state it was put away in.
    property var dismissed: ({})
    readonly property var waiting: AgentStatus.waitingSessions.filter(s => dismissed[s.id] !== s.state)
    readonly property var finished: AgentStatus.settings.peek === "finished"
        ? AgentStatus.justFinished.filter(s => dismissed[s.id] !== "finished:" + AgentStatus.finishedAt[s.id]) : []
    readonly property var subject: waiting.length ? waiting[0] : finished.length ? finished[0] : null
    // What the pill shows, kept while it fades out so the words don't change on the way.
    property var shown: null
    onSubjectChanged: if (subject) shown = subject
    readonly property bool wanted: AgentStatus.settings.peek !== "off" && subject !== null
        && !Ui.topShown && !Ui.overview && Ui.panel === ""

    implicitWidth: row.implicitWidth + 24
    implicitHeight: 30
    opacity: wanted ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.motion } }
    transform: Translate { y: root.wanted ? 0 : -12; Behavior on y { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } } }

    Glass { anchors.fill: parent; radius: 15 }
    Press {
        anchors.fill: parent
        radius: 15
        name: root.shown ? AgentStatus.title(root.shown) + (root.waiting.length ? " needs you" : " finished") : ""
        onClicked: Ui.open("agents")
        onSecondaryClicked: {
            const s = root.subject;
            if (!s)
                return;
            const next = Object.assign({}, root.dismissed);
            next[s.id] = s.state === "waiting" ? "waiting" : "finished:" + AgentStatus.finishedAt[s.id];
            root.dismissed = next;
        }
    }
    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 8
        Label {
            text: root.shown ? AgentStatus.face(root.shown) : ""
            font.family: "monospace"
            font.pixelSize: 12
            elide: Text.ElideNone
        }
        Label {
            Layout.maximumWidth: 280
            text: !root.shown ? ""
                : root.shown.state === "waiting"
                    ? AgentStatus.title(root.shown) + " needs you" + (root.shown.waiting ? " · " + AgentStatus.waitText(root.shown) : "")
                    : AgentStatus.title(root.shown) + " finished"
            font.pixelSize: 12
        }
        Label {
            visible: root.waiting.length + root.finished.length > 1
            text: "+" + (root.waiting.length + root.finished.length - 1)
            font.pixelSize: 11
            color: Theme.dim
        }
    }
}
