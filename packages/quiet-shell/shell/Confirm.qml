import QtQuick
import QtQuick.Layouts
import Quickshell

// Asks before anything that ends the session. Cancel holds the keyboard focus.
Item {
    id: root
    readonly property var ask: Ui.confirm
    anchors.fill: parent
    visible: ask !== null
    onVisibleChanged: if (visible) keys.forceActiveFocus()

    function accept() {
        const command = ask.command;
        Ui.confirm = null;
        Ui.close();
        Quickshell.execDetached(command);
    }
    // Enter confirms and Escape cancels, as the buttons' hints say. Tab still reaches
    // both. A held key never confirms, so a menu letter can't repeat into "yes".
    Item {
        id: keys
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape)
                Ui.confirm = null;
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !event.isAutoRepeat)
                root.accept();
            else
                return;
            event.accepted = true;
        }
    }

    MouseArea { anchors.fill: parent }
    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.25) }
    Item {
        anchors.centerIn: parent
        width: 300
        height: body.implicitHeight + 32
        Glass { anchors.fill: parent; radius: 24 }
        ColumnLayout {
            id: body
            x: 16
            y: 16
            width: parent.width - 32
            spacing: 6
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.ask ? root.ask.title : ""
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.ask ? root.ask.body : ""
                wrapMode: Text.Wrap
                color: Theme.dim
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                spacing: 8
                Press {
                    id: cancel
                    Layout.fillWidth: true
                    implicitHeight: 34
                    radius: 12
                    rest: Theme.fill
                    name: "Cancel"
                    onClicked: Ui.confirm = null
                    Keys.onEscapePressed: Ui.confirm = null
                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        Label { text: "Cancel"; font.weight: Font.Medium }
                        Label { anchors.verticalCenter: parent.verticalCenter; text: "Esc"; font.pixelSize: 10; color: Theme.faint }
                    }
                }
                Press {
                    Layout.fillWidth: true
                    implicitHeight: 34
                    radius: 12
                    rest: Theme.on
                    hover: Theme.on
                    name: root.ask ? root.ask.action : ""
                    onClicked: root.accept()
                    Keys.onEscapePressed: Ui.confirm = null
                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        Label { text: root.ask ? root.ask.action : ""; color: Theme.onText; font.weight: Font.Medium }
                        Label { anchors.verticalCenter: parent.verticalCenter; text: "↵"; font.pixelSize: 11; color: Theme.onText; opacity: 0.6 }
                    }
                }
            }
        }
    }
}
