import QtQuick
import QtQuick.Layouts

// The bar's agents panel (SUPER+A, or the agents button in the bar): every
// running session in the chosen style, the usage limits, and Customise, where
// the styles, what they show, and what the bar does are picked. `s` cycles the
// style, 1–9 go to that session's terminal, `c` folds Customise.
ColumnLayout {
    id: root
    width: 360
    spacing: 8
    readonly property bool customising: AgentStatus.customising

    onVisibleChanged: AgentStatus.watch(visible)
    function pressKey(text) {
        if (text === "s") {
            AgentStatus.cycleStyle();
            return true;
        }
        if (text === "c") {
            AgentStatus.customising = !AgentStatus.customising;
            return true;
        }
        const n = parseInt(text);
        if (n >= 1 && n <= 9 && AgentStatus.sessions[n - 1]) {
            AgentStatus.jump(AgentStatus.sessions[n - 1]);
            return true;
        }
        return false;
    }

    // Summary and style.
    Item {
        Layout.fillWidth: true
        implicitHeight: head.implicitHeight + 24
        Glass { anchors.fill: parent; radius: 22 }
        // A click on the card itself must not reach the backdrop, which closes the panel.
        MouseArea { anchors.fill: parent }
        ColumnLayout {
            id: head
            x: 16
            y: 12
            width: parent.width - 32
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                Label { text: "Agents"; font.pixelSize: 14; font.weight: Font.Medium }
                Item { Layout.fillWidth: true }
                Label {
                    text: [AgentStatus.waitingSessions.length ? AgentStatus.waitingSessions.length + " need you" : "",
                           AgentStatus.working ? AgentStatus.working + " working" : "",
                           AgentStatus.live - AgentStatus.working - AgentStatus.waitingSessions.length > 0
                               ? (AgentStatus.live - AgentStatus.working - AgentStatus.waitingSessions.length) + " idle" : ""]
                        .filter(x => x).join(" · ") || "none running"
                    font.pixelSize: 11
                    color: Theme.dim
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: AgentStatus.styles
                    Chip {
                        required property var modelData
                        text: modelData[1]
                        toggled: AgentStatus.settings.style === modelData[0]
                        onClicked: AgentStatus.set("style", modelData[0])
                    }
                }
                Item { Layout.fillWidth: true }
                Press {
                    name: root.customising ? "Done customising" : "Customise"
                    implicitWidth: 26
                    implicitHeight: 22
                    radius: 11
                    toggled: root.customising
                    rest: root.customising ? Theme.fill : "transparent"
                    onClicked: AgentStatus.customising = !AgentStatus.customising
                    Icon { anchors.centerIn: parent; name: "sliders-horizontal"; size: 13; color: Theme.dim }
                }
            }
        }
    }

    // Customise: everything the views can be, in one place.
    Item {
        visible: root.customising
        Layout.fillWidth: true
        implicitHeight: options.implicitHeight + 24
        Glass { anchors.fill: parent; radius: 22 }
        // A click on the card itself must not reach the backdrop, which closes the panel.
        MouseArea { anchors.fill: parent }
        ColumnLayout {
            id: options
            x: 16
            y: 12
            width: parent.width - 32
            spacing: 6
            Repeater {
                model: [
                    ["Overview card", "card", AgentStatus.styles],
                    ["Bar", "indicator", AgentStatus.indicators],
                    ["Pop up when", "peek", AgentStatus.peeks]
                ]
                ColumnLayout {
                    id: group
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 4
                    Label { text: group.modelData[0]; font.pixelSize: 10; color: Theme.faint }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: group.modelData[2]
                            Chip {
                                required property var modelData
                                text: modelData[1]
                                toggled: AgentStatus.settings[group.modelData[1]] === modelData[0]
                                onClicked: AgentStatus.set(group.modelData[1], modelData[0])
                            }
                        }
                    }
                }
            }
            Label { text: "Show"; font.pixelSize: 10; color: Theme.faint }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: AgentStatus.shows
                    Chip {
                        required property var modelData
                        text: modelData[1]
                        toggled: AgentStatus.shown(modelData[0])
                        onClicked: AgentStatus.toggleShow(modelData[0])
                    }
                }
            }
        }
    }

    // The sessions, scrolling when there are many.
    Item {
        Layout.fillWidth: true
        implicitHeight: Math.min(list.implicitHeight, 560) + 24
        Glass { anchors.fill: parent; radius: 22 }
        // A click on the card itself must not reach the backdrop, which closes the panel.
        MouseArea { anchors.fill: parent }
        Flickable {
            x: 12
            y: 12
            width: parent.width - 24
            height: parent.height - 24
            contentHeight: list.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            AgentList {
                id: list
                width: parent.width
                style: AgentStatus.settings.style
                feedRows: 18
            }
        }
    }

    Item {
        visible: AgentStatus.shown("limits") && AgentStatus.tools.length > 0
        Layout.fillWidth: true
        implicitHeight: limits.implicitHeight + 24
        Glass { anchors.fill: parent; radius: 22 }
        // A click on the card itself must not reach the backdrop, which closes the panel.
        MouseArea { anchors.fill: parent }
        AgentLimits {
            id: limits
            x: 16
            y: 12
            width: parent.width - 32
        }
    }
}
