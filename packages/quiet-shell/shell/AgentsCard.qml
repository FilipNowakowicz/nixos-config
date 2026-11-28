import QtQuick
import QtQuick.Layouts

// The overview's agents card: the usage limits, then the running sessions in the
// style chosen for it (Customise in the agents panel). The button in its corner
// opens that panel. It exists only while the overview is open, and asks for the
// full detail only then.
Item {
    id: root
    implicitHeight: body.implicitHeight + 24
    visible: AgentStatus.tools.length > 0 || AgentStatus.all.length > 0

    Component.onCompleted: AgentStatus.watch(true)
    Component.onDestruction: AgentStatus.watch(false)

    Glass { anchors.fill: parent; radius: 22 }
    ColumnLayout {
        id: body
        x: 16
        y: 12
        width: parent.width - 32
        spacing: 8
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Label { text: "Agents"; font.pixelSize: 12; font.weight: Font.Medium }
            Label {
                Layout.fillWidth: true
                text: [AgentStatus.waitingSessions.length ? AgentStatus.waitingSessions.length + " need you" : "",
                       AgentStatus.working ? AgentStatus.working + " working" : ""].filter(x => x).join(" · ")
                font.pixelSize: 10
                color: AgentStatus.waitingSessions.length ? Theme.text : Theme.dim
            }
            Press {
                name: "Open the agents panel"
                implicitWidth: 22
                implicitHeight: 22
                radius: 11
                onClicked: Ui.open("agents")
                Icon { anchors.centerIn: parent; name: "layout-grid"; size: 12; color: Theme.dim }
            }
        }
        AgentLimits { Layout.fillWidth: true; visible: AgentStatus.shown("limits") && AgentStatus.tools.length > 0 }
        AgentList {
            Layout.fillWidth: true
            visible: AgentStatus.all.length > 0
            style: AgentStatus.settings.card
            feedRows: 6
        }
    }
}
