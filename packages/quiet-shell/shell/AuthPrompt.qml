import QtQuick
import QtQuick.Layouts

// polkit asking for a password on behalf of an app.
Item {
    id: root
    readonly property var flow: Ui.auth
    anchors.fill: parent

    function ready() {
        if (visible && flow && flow.isResponseRequired)
            field.ask(flow.responseVisible);
    }
    onVisibleChanged: ready()
    onFlowChanged: ready()
    Connections {
        target: root.flow
        function onIsResponseRequiredChanged() { root.ready(); }
    }

    MouseArea { anchors.fill: parent }
    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.25) }
    Item {
        anchors.centerIn: parent
        width: 340
        height: body.implicitHeight + 32
        Glass { anchors.fill: parent; radius: 24 }
        ColumnLayout {
            id: body
            x: 16
            y: 16
            width: parent.width - 32
            spacing: 6
            Icon {
                Layout.alignment: Qt.AlignHCenter
                name: "lock"
                size: 22
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: "Authentication required"
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.flow ? root.flow.message : ""
                wrapMode: Text.Wrap
                color: Theme.dim
            }
            PasswordRow {
                id: field
                Layout.fillWidth: true
                Layout.topMargin: 8
                enabled: !!root.flow && root.flow.isResponseRequired
                network: "this action"
                action: "Allow"
                placeholder: root.flow ? root.flow.inputPrompt.replace(/:\s*$/, "") || "Password" : "Password"
                onSubmitted: value => root.flow.submit(value)
                onCancelled: root.flow.cancelAuthenticationRequest()
            }
            Label {
                Layout.fillWidth: true
                visible: text !== ""
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: Theme.dim
                text: !root.flow ? ""
                    : root.flow.supplementaryMessage !== "" ? root.flow.supplementaryMessage
                    : root.flow.failed ? "That password didn't work."
                    : ""
            }
            Press {
                Layout.fillWidth: true
                Layout.topMargin: 6
                implicitHeight: 34
                radius: 12
                rest: Theme.fill
                name: "Cancel"
                onClicked: root.flow.cancelAuthenticationRequest()
                Label { anchors.centerIn: parent; text: "Cancel"; font.weight: Font.Medium }
            }
        }
    }
}
