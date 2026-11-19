import QtQuick
import QtQuick.Layouts

// One running agent session in the overview: what it is and whether it is working.
// A click jumps to its terminal, found through kitty's remote-control socket; a
// session in a terminal started before that existed cannot be jumped to.
// A Claude session also has a switch to carry on by itself after a usage limit:
// scripts/resume.py types into it once the limit resets.
ColumnLayout {
    id: root
    required property var session
    readonly property bool reachable: !!session.terminal
    readonly property bool working: session.state === "working"
    // What a click on the switch just did, said for a moment in place of the state.
    property string sent: ""
    // How long until the limit that stopped it resets, as the card words it.
    property string back: ""
    readonly property bool limited: session.limited !== null && session.limited !== undefined
    // A click shows at once; the next poll rebuilds the row from the switch's file.
    property var pending: null
    readonly property bool resumes: pending !== null ? pending : !!session.resume
    signal jump
    signal setResume(bool on)

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
                        : root.limited ? (root.resumes ? "resumes " : "limit · back ")
                                         + (root.back !== "" ? "in " + root.back : "now")
                        : [root.session.context !== null ? "ctx " + Math.round(root.session.context) + "%" : "",
                           root.working ? "working" : "idle"].filter(s => s).join(" · ")
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                }
            }
        }
        Press {
            visible: root.reachable && root.session.tool === "claude" && !!root.session.key
            implicitWidth: 24
            implicitHeight: 24
            radius: 12
            checkable: true
            toggled: root.resumes
            // Lit while on, as a chosen option is elsewhere in the shell.
            rest: root.resumes ? Theme.on : "transparent"
            hover: root.resumes ? Theme.on : Theme.fillHover
            name: (root.resumes ? "Stop resuming " : "Resume after the usage limit: ")
                + (root.session.name || root.session.project)
            onClicked: {
                const on = !root.resumes;
                root.pending = on;
                root.setResume(on);
                root.sent = on ? "resumes after the limit" : "won't resume";
                sentTimer.restart();
            }
            Icon { anchors.centerIn: parent; name: "timer"; size: 13; color: root.resumes ? Theme.onText : Theme.dim }
        }
    }

    Timer { id: sentTimer; interval: 2500; onTriggered: root.sent = "" }
}
