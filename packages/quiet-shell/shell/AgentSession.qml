import QtQuick
import QtQuick.Layouts

// One running agent session in the overview: what it is and whether it is working.
// A click jumps to its terminal; the reply button opens a line whose Return types
// the text into that terminal and presses Enter, as if typed there. Both need the
// kitty window it runs in, found through kitty's remote-control socket; a session
// in a terminal started before that existed offers neither.
ColumnLayout {
    id: root
    required property var session
    readonly property bool reachable: !!session.terminal
    readonly property bool working: session.state === "working"
    property bool replying: false
    property string sent: ""
    signal jump
    signal reply(string text)

    spacing: 4

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Rectangle {
            implicitWidth: 6
            implicitHeight: 6
            radius: 3
            color: root.working ? Theme.accent : Theme.faint
            SequentialAnimation on opacity {
                running: root.working && !Theme.reducedMotion
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                onStopped: parent.opacity = 1
            }
        }
        Press {
            Layout.fillWidth: true
            implicitHeight: 24
            radius: 8
            enabled: root.reachable
            name: "Go to " + (root.session.name || root.session.project)
            onClicked: root.jump()
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 4
                spacing: 6
                Label {
                    Layout.fillWidth: true
                    // The session's own name, and the project when the name doesn't say it.
                    text: [root.session.name, root.session.project].filter((s, i, all) => s && (i === 0 || !all[0].startsWith(s))).join(" · ") || "~"
                    elide: Text.ElideRight
                    font.pixelSize: 12
                }
                Label {
                    text: root.sent !== "" ? root.sent
                        : [root.session.context !== null ? "ctx " + Math.round(root.session.context) + "%" : "",
                           root.working ? "working" : "idle"].filter(s => s).join(" · ")
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                }
            }
        }
        Press {
            visible: root.reachable
            implicitWidth: 24
            implicitHeight: 24
            radius: 12
            checkable: true
            toggled: root.replying
            name: "Reply to " + (root.session.name || root.session.project)
            onClicked: {
                root.replying = !root.replying;
                if (root.replying)
                    input.forceActiveFocus();
            }
            Icon { anchors.centerIn: parent; name: "reply"; size: 13; color: root.replying ? Theme.text : Theme.dim }
        }
    }

    Item {
        visible: root.replying
        Layout.fillWidth: true
        implicitHeight: 34
        Rectangle {
            anchors.fill: parent
            radius: 10
            color: Theme.fill
            border.width: input.activeFocus ? 1 : 0
            border.color: Theme.accent
        }
        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 11
            anchors.rightMargin: 11
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.text
            selectionColor: Theme.accent
            font.family: Theme.font
            font.pixelSize: 12
            clip: true
            Accessible.role: Accessible.EditableText
            Accessible.name: "Reply to " + (root.session.name || root.session.project)
            Keys.onReturnPressed: {
                if (text.trim() === "")
                    return;
                root.reply(text);
                text = "";
                root.replying = false;
                root.sent = "sent";
                sentTimer.restart();
            }
            Keys.onEscapePressed: event => {
                // Escape clears the line, then folds it away; after that it closes the overview.
                if (text !== "") text = "";
                else root.replying = false;
            }
            Label {
                anchors.verticalCenter: parent.verticalCenter
                visible: input.text === ""
                text: "Type, then Return to send"
                font.pixelSize: 12
                color: Theme.faint
            }
        }
    }
    Timer { id: sentTimer; interval: 2500; onTriggered: root.sent = "" }
}
