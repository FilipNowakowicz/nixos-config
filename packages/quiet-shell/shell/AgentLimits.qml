import QtQuick
import QtQuick.Layouts

// How much of each subscribed tool's usage limits is spent and when each comes
// back, on the thin track the sliders use; it brightens near the end. Where the
// pace says a window fills before it resets, it says when. A tool whose
// subscription has ended is left out, even while its last limits are on record.
ColumnLayout {
    id: root
    spacing: 4
    visible: AgentStatus.tools.length > 0

    Repeater {
        model: AgentStatus.tools
        ColumnLayout {
            id: tool
            required property var modelData
            readonly property var limits: AgentStatus.info[modelData[1]]
            Layout.fillWidth: true
            spacing: 3
            Repeater {
                model: [["5h", tool.limits.five_hour], ["week", tool.limits.week]].filter(w => w[1] !== null)
                RowLayout {
                    id: limit
                    required property var modelData
                    required property int index
                    readonly property var w: modelData[1]
                    readonly property bool soon: !!w.runs_out
                    Layout.fillWidth: true
                    spacing: 8
                    Label {
                        Layout.preferredWidth: 72
                        text: (limit.index === 0 ? tool.modelData[0] + " " : "") + limit.modelData[0]
                        font.pixelSize: 10
                        color: limit.index === 0 ? Theme.dim : Theme.faint
                    }
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: 4
                        Rectangle { anchors.fill: parent; radius: 2; color: Theme.track }
                        Rectangle {
                            width: parent.width * Math.min(100, limit.w.used) / 100
                            height: parent.height
                            radius: 2
                            color: limit.w.used >= 90 || limit.soon ? Theme.text : Theme.accent
                            opacity: limit.w.used >= 90 ? 1 : 0.85
                            Behavior on width { NumberAnimation { duration: Theme.motion } }
                        }
                    }
                    Label {
                        Layout.preferredWidth: 104
                        horizontalAlignment: Text.AlignRight
                        text: limit.w.used + "%" + (limit.soon ? " · out " + AgentStatus.clock(limit.w.runs_out)
                            : limit.w.resets ? " · " + AgentStatus.until(limit.w.resets) : "")
                        font.pixelSize: 10
                        font.features: { "tnum": 1 }
                        font.weight: limit.soon ? Font.DemiBold : Font.Normal
                        color: limit.w.used >= 90 || limit.soon ? Theme.text : Theme.dim
                    }
                }
            }
        }
    }
}
