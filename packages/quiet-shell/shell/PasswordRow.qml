import QtQuick
import QtQuick.Layouts

// Asks for a Wi-Fi password in place, under the network it belongs to.
Item {
    id: root
    property string network
    property string action: "Join"
    property string placeholder: "Password"
    signal submitted(string password)
    signal cancelled

    implicitHeight: 44
    function ask(visibleText) {
        reveal.toggled = !!visibleText;
        input.text = "";
        input.forceActiveFocus();
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 3
        radius: 12
        color: Theme.fill
        border.width: input.activeFocus ? 1 : 0
        border.color: Theme.accent
    }
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 13
        anchors.rightMargin: 7
        spacing: 6
        TextInput {
            id: input
            Layout.fillWidth: true
            color: Theme.text
            selectionColor: Theme.accent
            font.family: Theme.font
            font.pixelSize: 14
            echoMode: reveal.toggled ? TextInput.Normal : TextInput.Password
            clip: true
            Accessible.role: Accessible.EditableText
            Accessible.name: "Password for " + root.network
            Accessible.passwordEdit: !reveal.toggled
            Keys.onReturnPressed: join.clicked()
            Keys.onEscapePressed: root.cancelled()
            Label {
                anchors.verticalCenter: parent.verticalCenter
                visible: input.text === ""
                text: root.placeholder
                color: Theme.dim
            }
        }
        Press {
            id: reveal
            implicitWidth: 26
            implicitHeight: 26
            radius: 9
            checkable: true
            name: toggled ? "Hide password" : "Show password"
            onClicked: toggled = !toggled
            Icon { anchors.centerIn: parent; name: reveal.toggled ? "eye-off" : "eye"; size: 14; color: Theme.dim }
        }
        Press {
            id: join
            implicitWidth: actionLabel.implicitWidth + 20
            implicitHeight: 26
            radius: 9
            rest: Theme.fill
            enabled: input.text !== ""
            opacity: enabled ? 1 : 0.5
            name: root.action + " " + root.network
            onClicked: root.submitted(input.text)
            Label { id: actionLabel; anchors.centerIn: parent; text: root.action; font.pixelSize: 12; font.weight: Font.Medium }
        }
    }
}
